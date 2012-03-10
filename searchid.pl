use Modern::Perl;
use autodie;
use POE;
use POE::Wheel::SocketFactory;
use POE::Session;
use POE::Wheel::ReadWrite;
use Socket;
use AnyEvent::Inotify::Simple;
use File::Find::Object;
use Time::HiRes qw/gettimeofday/;
use Getopt::Long;

my $directory;
my $unix_socket = '/tmp/searchi';

GetOptions(
    'd|directory=s' => \$directory
);

sub searcher_start {
    my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

    $heap->{dir}   = $directory;
    $heap->{index} = {};

    say "Initializing tree";
    my $tree = File::Find::Object->new({}, $heap->{dir});

    while (my $file = $tree->next) {
        next if $file ~~ m/\/\.git\//;
        next if -d $file;
        $kernel->post($session, 'add_file', $file);
    }

    AnyEvent::Inotify::Simple->new(
        directory      => $heap->{dir},
        event_receiver => sub {
            my ($event, $file, $moved_to) = @_;
            return if $file ~~ m/^\.git/;
            return if -d ($heap->{dir} . "/$file");
            my $fullpath = $heap->{dir} . $file;
            given ($event) {
                when ([qw/create attribute_change moved_to/]) {
                    $kernel->post($session, 'add_file', $fullpath);
                }
                when ([qw/delete moved_from/]) {
                    $kernel->post($session, 'remove_file', $fullpath);
                }
                when ('modify') {
                    $kernel->post($session, 'remap_file', $fullpath);
                }
            };
        },
    );
}

sub open_map {
    my ($index, $file) = @_;
    unless (exists $index->{$file}) {
        open my $fh, '<:mmap', $file;
        $index->{$file} = $fh;
    }
}

sub unmap {
    my ($index, $file) = @_;
    if (exists $index->{$file}) {
        close $index->{$file};
        delete $index->{$file};
    }
}

sub add_file {
    my ($kernel, $session, $heap, $file) = @_[KERNEL, SESSION, HEAP, ARG0];

    open_map($heap->{index}, $file);
}

sub remove_file {
    my ($kernel, $session, $heap, $file) = @_[KERNEL, SESSION, HEAP, ARG0];

    unmap($heap->{index}, $file);
}

sub remap_file {
    my ($kernel, $session, $heap, $file) = @_[KERNEL, SESSION, HEAP, ARG0];

    unmap($heap->{index}, $file);
    open_map($heap->{index}, $file);
}

sub search {
    my ($kernel, $heap, $term, $client, $clientsession) = @_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    my $index = $heap->{index};

    say "looking for $term";
    my $start = gettimeofday;
    for my $file (keys %$index) {
        my $fh          = $index->{$file};
        my $line_number = 1;

        while (my $line = <$fh>) {
            if ($line =~ m/$term/) {
                chomp $line;
                $client->put("Found $term in $file on line $line_number: $line");
            }
            $line_number++;
        }
        seek $fh, 0, 0;
    }

    $kernel->post($clientsession, 'done');

    my $duration = gettimeofday - $start;
    say "Took $duration seconds";
}

my $searcher = POE::Session->create(
    inline_states => {
        _start      => \&searcher_start,
        add_file    => \&add_file,
        remove_file => \&remove_file,
        remap_file  => \&remap_file,
        search      => \&search,
    }
);

sub server_error {
    my ($heap) = $_[HEAP];
    delete $heap->{server};
}

sub client_input {
    my ($kernel, $session, $heap, $input) = @_[KERNEL, SESSION, HEAP, ARG0];
    my ($command, $args) = split ' ', $input, 2;
    say "got input $input";
    given ($command) {
        when ('search') {
            $kernel->post($searcher, 'search', $args, $heap->{client}, $session);
        }
        default {
            say "Unknown command: $command";
        }
    }
}

sub client_error {
    my ($heap, $operation, $errnum, $errstr, $id) = @_[HEAP, ARG0..ARG3];
    unless ($operation eq "read" and $errnum == 0) {
        delete $heap->{client};
    }
}

sub client_done {
    my ($heap) = $_[HEAP];
    $heap->{client}->shutdown_output;
    delete $heap->{client};
}

sub client_start {
    my ($heap, $socket) = @_[HEAP, ARG0];
    $heap->{client} = POE::Wheel::ReadWrite->new(
        Handle     => $socket,
        InputEvent => 'got_client_input',
        ErrorEvent => 'got_client_error',
    );
}

sub new_client {
    my ($client_socket) = $_[ARG0];
    POE::Session->create(
        inline_states => {
            _start           => \&client_start,
            got_client_input => \&client_input,
            got_client_error => \&client_error,
            done             => \&client_done,
        },
        args => [$client_socket],
    );
}

sub server_started {
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    unlink $unix_socket if -e $unix_socket;

    $heap->{server} = POE::Wheel::SocketFactory->new(
        SocketDomain => PF_UNIX,
        BindAddress  => $unix_socket,
        SuccessEvent => 'got_client',
        FailureEvent => 'got_error',
    );
}

my $unix_server = POE::Session->create(
    inline_states => {
        _start     => \&server_started,
        got_client => \&new_client,
        got_error  => \&server_error,
    },
);

say 'Ready';
POE::Kernel->run;
exit 0;
