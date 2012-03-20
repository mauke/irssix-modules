package IrssiX::Async;

use warnings;
use strict;

our $VERSION = '0.08';

use Carp qw(croak);
use Errno;
use POSIX ();
use IO::Handle ();
use Irssi ();

use again 'IrssiX::Util' => qw(run_from_package puts);

use Exporter qw(import);
our @EXPORT_OK = qw(
	fork_off
);

sub fork_off {
	my ($in_data, $body, $done) = @_;
	my $caller = caller;

	my $out = '';
	my $err = '';
	my $async = IrssiX::Async->new(
		_caller => $caller,
		on_stdout => sub {
			my ($self, $str) = @_;
			$out .= $str;
		},
		on_stderr => sub {
			my ($self, $str) = @_;
			$err .= $str;
		},
		on_end => sub {
			my ($self, $status) = @_;
			$done->($out, $err, $status);
		},
	);
	eval { $async->run($body); 1 } or return $done->('', "$@", undef);
	$async->send($in_data);
	$async->send_eof;
}

sub new {
	my $class = shift;

	my $caller = caller;
	my $self = bless {}, $class;
	$self->_init(_caller => $caller, @_);
	$self
}

sub _init {
	my $self = shift;
	my %param = @_;
	$self->{_pid} = undef;
	$self->{_stdin_done} = 0;
	$self->{_stdin_pending} = '';
	$self->{_stdout_done} = 0;
	$self->{_stderr_done} = 0;
	$self->{_exit_status} = undef;
	$self->{_caller} = delete $param{_caller};
	for my $k (qw(on_stdout on_stdout_eof on_stderr on_stderr_eof on_end on_exit_)) {
		$self->$k(delete $param{$k});
	}
	%param and croak "${\ref $self}::_init(): invalid config key(s): @{[keys %param]}";
}

BEGIN {
	for my $k (qw(on_stdout on_stdout_eof on_stderr on_stderr_eof on_end on_exit_)) {
		my $ref = do {no strict 'refs'; \*$k};
		*$ref = sub {
			my $self = shift;
			my ($f) = @_;
			$self->{_pid} and croak "${\ref $self}::$k(): already running";
			$self->{"_$k"} = $f;
		};
	}
}

sub _finalize_stdin {
	my $self = shift;
	if (my $tag_in = delete $self->{_tag_in}) {
		run_from_package $self->{_caller}, \&Irssi::input_remove, $tag_in;
	}
	$self->{_stdin_done} = 1;
	close $self->{_in_w};
	$self->{_in_w} = undef;
	$self->_check_end;
}

sub send_eof {
	my $self = shift;
	$self->{_stdin_done} and return;
	$self->{_pid} or croak "${\ref $self}::send_eof(): not running yet";
	$self->{_stdin_done} = 1;
	if ($self->{_stdin_pending} eq '') {
		$self->_finalize_stdin;
	}
}

sub send {
	my $self = shift;
	my ($str) = @_;
	$self->{_pid} or croak "${\ref $self}::send(): not running yet";
	defined $self->{_exit_status} and croak "${\ref $self}::send(): already died";
	$self->{_stdin_done} and return;
	$self->{_stdin_pending} .= $str;

	$self->{_stdin_pending} eq '' || $self->{_tag_in} and return;

	$self->{_tag_in} = run_from_package $self->{_caller}, \&Irssi::input_add, fileno($self->{_in_w}), Irssi::INPUT_WRITE, sub {
		if ($self->{_stdin_pending} ne '') {
			my $n = syswrite $self->{_in_w}, $self->{_stdin_pending};
			if (!defined $n) {
				$self->_finalize_stdin unless $!{EWOULDBLOCK} || $!{EAGAIN};
				return;
			}
			substr $self->{_stdin_pending}, 0, $n, '';
			$self->{_stdin_pending} eq '' or return;
		}
		run_from_package $self->{_caller}, \&Irssi::input_remove, delete $self->{_tag_in};
		if ($self->{_stdin_done}) {
			$self->_finalize_stdin;
		}
	}, undef;
}

sub _register_exit_handler_in {
	my ($pkg) = @_;
	my $prefix = '?__irssix_async1_';
	my $name = $prefix . 'pidwait';
	my $full_name = $pkg . '::' . $name;
	my $ref = do { no strict 'refs'; \%$full_name and \*$full_name };
	unless (*$ref{CODE}) {
		my $pending = *$ref{HASH};
		*$ref = sub {
			my ($dead_pid, $status) = @_;
			my $entry = delete $pending->{$dead_pid} or return;
			$entry->($status);
		};
		run_from_package $pkg, \&Irssi::signal_add, 'pidwait', $name;
	}
	*$ref{HASH}
}

sub _call_h {
	my $self = shift;
	my $h = shift;
	if (my $f = $self->{"_$h"}) {
		$f->($self, @_);
	}
}

sub run {
	my $self = shift;
	my ($body) = @_;

	my $method = ref($self) . "::run()";

	pipe my $in_r,  my $in_w  or die "$method: pipe(): $!\n";
	pipe my $out_r, my $out_w or die "$method: pipe(): $!\n";
	pipe my $err_r, my $err_w or die "$method: pipe(): $!\n";
	
	defined(my $pid = fork) or die "$method: fork(): $!\n";

	if (!$pid) {
		delete $SIG{__WARN__};
		delete $SIG{__DIE__};

		close $in_w;
		close $out_r;
		close $err_r;

		open STDIN, '<&', $in_r;
		open STDOUT, '>&', $out_w;
		open STDERR, '>&', $err_w;
		select STDOUT;

		close $in_r;
		close $out_w;
		close $err_w;

		POSIX::close $_ for 3 .. 255;

		eval { $body->(); 1 } or print STDERR $@;

		close STDOUT;
		close STDERR;

		POSIX::_exit 0;
	} else {
		$self->{_pid} = $pid;

		close $_ for $in_r, $out_w, $err_w;
		$_->blocking(0) for $in_w, $out_r, $err_r;

		my $caller = $self->{_caller};

		my $pending = _register_exit_handler_in $caller;
		$pending->{$pid} = sub {
			my ($status) = @_;
			$self->{_exit_status} = $status;
			$self->_call_h(on_exit_ => $status);
			$self->_check_end;
		};

		$self->{_in_w} = $in_w;

		my $tag_out;
		$tag_out = run_from_package $caller, \&Irssi::input_add, fileno($out_r), Irssi::INPUT_READ, sub {
			my $n = sysread $out_r, my $buf, 1024;
			if ($n) {
				$self->_call_h(on_stdout => $buf);
				return;
			}
			if (!defined($n) && ($!{EWOULDBLOCK} || $!{EAGAIN})) {
				return;
			}
			run_from_package $caller, \&Irssi::input_remove, $tag_out;
			close $out_r;
			$self->{_stdout_done} = 1;
			$self->_call_h(on_stdout_eof =>);
			$self->_check_end;
		}, undef;

		my $tag_err;
		$tag_err = run_from_package $caller, \&Irssi::input_add, fileno($err_r), Irssi::INPUT_READ, sub {
			my $n = sysread $err_r, my $buf, 1024;
			if ($n) {
				$self->_call_h(on_stderr => $buf);
				return;
			}
			if (!defined($n) && ($!{EWOULDBLOCK} || $!{EAGAIN})) {
				return;
			}
			run_from_package $caller, \&Irssi::input_remove, $tag_err;
			close $err_r;
			$self->{_stderr_done} = 1;
			$self->_call_h(on_stderr_eof =>);
			$self->_check_end;
		}, undef;

		run_from_package $caller, \&Irssi::pidwait_add, $pid;
	}
}

sub _check_end {
	my $self = shift;
	(
		$self->{_pid} &&
		!$self->{_in_w} &&
		$self->{_stdout_done} &&
		$self->{_stderr_done} &&
		defined $self->{_exit_status}
	) or return;
	$self->_call_h(on_end => $self->{_exit_status});
}

sub DESTROY {
	my $self = shift;
	$self->send_eof if $self->{_pid};
}

{
	package IrssiX::Async::Lines;
	use Carp qw(croak);

	our @ISA = 'IrssiX::Async';

	sub new {
		my $class = shift;
		my $caller = caller;
		my $self = bless {}, $class;
		$self->_init(_caller => $caller, @_);
		$self
	}

	sub _init {
		my $self = shift;
		my %param = @_;
		$self->{_stdout_pending} = '';
		$self->{_stderr_pending} = '';
		for my $k (qw(on_stdout_line on_stderr_line)) {
			$self->$k(delete $param{$k});
		}
		for my $var (qw(out err)) {
			$self->${\"SUPER::on_std${var}"}(sub {
				my ($self, $str) = @_;
				$self->_call_h("on_std${var}2" => $str);
				my $pending = $self->{"_std${var}_pending"};
				while ((my $p = index $str, "\n") >= 0) {
					$self->_call_h("on_std${var}_line" => $pending . substr($str, 0, $p));
					$pending = '';
					substr $str, 0, $p + 1, '';
				}
				$self->{"_std${var}_pending"} = $pending . $str;
			});
			$self->${\"SUPER::on_std${var}_eof"}(sub {
				my ($self) = @_;
				for my $vp ($self->{"_std${var}_pending"}) {
					$vp eq '' and last;
					$self->_call_h("on_std${var}_line" => $vp);
					$vp = '';
				}
				$self->_call_h("on_std${var}_eof2");
			});
		}
		$self->SUPER::_init(%param);
	}

	BEGIN {
		for my $k (qw(on_stdout_line on_stderr_line)) {
			my $ref = do {no strict 'refs'; \*$k};
			*$ref = sub {
				my $self = shift;
				my ($f) = @_;
				$self->{_pid} and croak "${\ref $self}::$k(): already running";
				$self->{"_$k"} = $f;
			};
		}

		for my $k (qw(on_stdout on_stderr)) {
			my $ref = do {no strict 'refs'; \*$k};
			*$ref = sub {
				my $self = shift;
				my ($f) = @_;
				$self->{_pid} and croak "${\ref $self}::$k(): already running";
				$self->{"_${k}2"} = $f;
			};
		}
	}

	sub send_line {
		my $self = shift;
		my ($str) = @_;
		$self->send($str . "\n");
	}
}

'ok'

__END__

=head1 NAME

IrssiX::Async - run code in the background to keep irssi responsive

=head1 SYNOPSIS

  use IrssiX::Async qw(fork_off);
  
  fork_off $stdin_data, sub {
    # runs in a background process
    ...
  }, sub {
    # runs when the background process completes
    my ($stdout_data, $stderr_data, $exit_status) = @_;
    ...
  };


  # or:
  my $async = IrssiX::Async->new(
    on_stdout => sub {
      my ($self, $stdout_data) = @_;
      # runs when the background process writes to stdout
      ...
    },
    on_stderr => sub {
      my ($self, $stderr_data) = @_;
      # runs when the background process writes to stderr
      ...
    },
    on_end => sub {
      my ($self, $exit_status) = @_;
      # runs when the background process has exited and closed all streams
      ...
    },
  );
  $async->run(sub {
    # runs in a background process
    ...
  });
  $async->send($stdin_data);
  $async->send_eof;


  # or:
  my $async = IrssiX::Async::Lines->new(
    on_stdout_line => sub {
      my ($self, $stdout_line) = @_;
      # runs when the background process writes a line to stdout
      ...
    },
    on_stderr_line => sub {
      my ($self, $stderr_line) = @_;
      # runs when the background process writes a line to stderr
      ...
    },
    on_end => sub {
      my ($self, $exit_status) = @_;
      # runs when the background process has exited and closed all streams
      ...
    },
  );
  ...

=head1 DESCRIPTION

Sometimes you want to do something in an irssi script that may take a long
time, such as downloading a file. While you can just use L<LWP::Simple/get> for
this, irssi will hang until the call completes.

This module provides a simple way to run blocking code in the background,
notifying you when it's done. It exports nothing by default.

=head2 Importable functions

=over

=item fork_off $STDIN, $BODY, $DONE

This function will spawn a new process and run C<< $BODY->() >> in it. The new
process won't be able to call any irssi functions, so don't try. All
communication should go through the C<STDIN>, C<STDOUT>, and C<STDERR> handles.
What you pass as C<$STDIN> will arrive on the new process's C<STDIN>.

When the new process exits (by returning from C<$BODY>),
C<< $DONE->($stdout, $stderr, $status) >> will be called. Here C<$stdout> is
the collected standard output of the process, C<$stderr> is the collected
standard error output, and C<$status> is the exit status (probably in the same
format as L<perlvar/"$?">). If anything goes wrong in the setup/creation of the
child process, C<$DONE> is still called with the error message in C<$stderr>
but C<$status> will be C<undef>.

=back

=head2 Object-based interface: IrssiX::Async

If you need more control than what L<fork_off> offers, you can use the
following object-based interface.

=head3 Constructor

=over

=item new

C<< IrssiX::Async->new(%param) >> constructs an object based on a key-value
list. The following keys can be specified:

=over

=item _caller => $package

C<IrssiX::Async> needs to install a handler function in the calling script for
reasons. By default it injects code into the package of the calling code (as
returned by L<perlfunc/caller>). If you need to override this for some reason,
you can specify a different package with C<_caller>.

=item on_stdout => $sub

Calls C<< $self->on_stdout($sub) >>. See L</on_stdout>

=item on_stdout_eof => $sub

Calls C<< $self->on_stdout_eof($sub) >>. See L</on_stdout_eof>

=item on_stderr => $sub

Calls C<< $self->on_stderr($sub) >>. See L</on_stderr>

=item on_stderr_eof => $sub

Calls C<< $self->on_stderr_eof($sub) >>. See L</on_stderr_eof>

=item on_exit_ => $sub

Calls C<< $self->on_exit_($sub) >>. See L</on_exit_>

=item on_end => $sub

Calls C<< $self->on_end($sub) >>. See L</on_end>

=back

=back

=head3 Methods

=over

=item on_stdout

A setter taking a code reference that will be called every time the child
process writes to C<STDOUT>. It will receive two arguments: the
C<IrssiX::Async> object itself, and the string that was read.

=item on_stdout_eof

A setter taking a code reference that will be called when the child process
closes its C<STDOUT>. It will receive one argument: the C<IrssiX::Async> object
itself.

=item on_stderr

A setter taking a code reference that will be called every time the child
process writes to C<STDERR>. It will receive two arguments: the
C<IrssiX::Async> object itself, and the string that was read.

=item on_stderr_eof

A setter taking a code reference that will be called when the child process
closes its C<STDERR>. It will receive one argument: the C<IrssiX::Async> object
itself.

=item on_exit_

A setter taking a code reference that will be called when the child process
exits. It will receive two arguments: the C<IrssiX::Async> object itself, and
the exit status.

=item on_end

A setter taking a code reference that will be called after the child has exited
and its C<STDOUT>/C<STDERR> handles are closed; i.e. after C<on_end> no more
data will arrive via C<on_stdout> or C<on_stderr>. It will receive two
arguments: the C<IrssiX::Async> object itself, and the exit status.

=item run

Takes a code reference and runs it in a child process. The new process won't be
able to call any irssi functions, so don't try. All communication should go
through the C<STDIN>, C<STDOUT>, and C<STDERR> handles.

=item send

Takes a string and buffers it for sending to the child process's C<STDIN> as
soon as possible.

=item send_eof

Sends EOF to the child's C<STDIN> by closing the corresponding write handle in
the parent. You should call this immediately after L</run> if you have no data
to send.

=back

=head2 Object-based interface: IrssiX::Async::Lines

But wait, there's more! Included in this module there's an C<IrssiX::Async>
subclass called C<IrssiX::Async::Lines>. It provides all the constructor
parameters and methods listed above plus the following:

=over

=item on_stdout_line

A code reference that will be called when the child process has written a
complete line to C<STDOUT>. It will receive two arguments: the
C<IrssiX::Async::Lines> object itself and the line (without the trailing
newline).

=item on_stderr_line

A code reference that will be called when the child process has written a
complete line to C<STDERR>. It will receive two arguments: the
C<IrssiX::Async::Lines> object itself and the line (without the trailing
newline).

=item send_line

This method sends a line to the child's C<STDIN>.
C<< $async->send_line($line) >> is equivalent to C<< $async->send("$line\n") >>.

=back

=head1 CAVEATS

L</fork_off> and L</run> currently close all open file descriptors (except for
C<STDIN>, C<STDOUT>, and C<STDERR>) in the child process.

=head1 COPYRIGHT & LICENSE

Copyright 2011, 2012 Lukas Mai.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU Lesser General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.

=cut
