Searchi
=======

Searchi represents about 3 hours of a Friday night where I got bored and wanted to see if I could make a Linuxy daemon that operated similar to the file search functionality of [IBB](https://github.com/chadaustin/ibb).

It's a few hundred lines of Perl, using POE for the eventing system, and inotify to know when to remap files.

It's still very, very primitive. My testing indicates that it's generally faster than ack, and even faster than grep if you have a bunch of small files (test case here was about 800 files in 6.2MB).

I expect to do more restructuring before it's reasonably usable. I'd eventually like to have an accompanying vim plugin.
