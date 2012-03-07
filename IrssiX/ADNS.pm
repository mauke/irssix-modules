package IrssiX::ADNS;

use warnings;
use strict;
use again 'IrssiX::Async' => [];

our $VERSION = '0.02';

`which adnshost 2>&1`;
$? and die "Can't find the 'adnshost' program";

sub new {
	my $class = shift;
	my $caller = caller;

	my $adns = {
		uniq => 'A',
		pending => {},
	};

	my $async = IrssiX::Async::Lines->new(
		_caller => $caller,
		on_stdout_line => sub {
			my ($self, $str) = @_;

			if ($adns->{redir_lines}) {
				$adns->{redir_lines}--;
				if ($str =~ /^\S+ A INET (\S+)/) {
					push @{$adns->{redir_results}}, $1;
				}
				$adns->{redir_lines} and return;

				delete $adns->{redir_lines};
				my $r = delete $adns->{redir_results};
				my $id = delete $adns->{redir_target};
				my $k = delete $adns->{pending}{$id};
				return @$r ? $k->[1](@$r) : $k->[0]();
			}

			my
				        (  $id,      $nrss,    $statustype, $statusnum, $statusabbrev, $owner, $ttl,       $cname, $statusstring) =
				$str =~ m{^([A-Z]+)\ ([0-9]+)\ (\S+)      \ ([0-9]+)  \ (\S+)        \ (\S+) \ (?:[0-9]+ )?(\S+)\ "(.*)"\s*\z}x
				or die "wtf adns: $str"
			;
			if ($nrss) {
				$adns->{redir_lines} = $nrss;
				$adns->{redir_results} = [];
				$adns->{redir_target} = $id;
				return;
			}
			my $k = delete $adns->{pending}{$id};
			$k->[0]($statusabbrev, $statusstring);
		},
		on_end => sub {
		},
	);

	$async->run(sub {
		exec qw(adnshost -a -f);
		die "adnshost: $!\n";
	});

	my $self = bless {
		async => $async,
		adns => $adns,
	}, $class;

	$self
}

sub resolve {
	my $self = shift;
	my ($host, $k_fail, $k_success) = @_;

	my $adns = $self->{adns};
	my $id = $adns->{uniq}++;
	$adns->{pending}{$id} = [$k_fail, $k_success];
	$self->{async}->send("--asynch-id $id\n- $host\n");
}

sub DESTROY {}

'ok'
__END__

=head1 NAME

IrssiX::ADNS - asynchronously resolve IP addresses with adnshost

=head1 SYNOPSIS

  use IrssiX::ADNS;
  
  my $adns = IrssiX::ADNS->new;
  $adns->resolve(
    $host,
    sub {
      # an error occurred
      ...
    },
    sub {
      # success!
      my @adresses = @_;
      ...
    },
  );

=head1 DESCRIPTION

To resolve a host name to its ip address, you can use
L<perlfunc/gethostbyname>. Unfortunately name resolution can take a long time,
during which irssi will be unresponsive. This module offers a relatively simple
replacement based on L<adnshost(1)> and L<IrssiX::Async>; i.e. you need the
C<adnshost> program somewhere in your path to use this module.

=head2 Methods

=over

=item new

The constructor. It takes no arguments and starts an C<adnshost> instance in
the background.

=item resolve

The only available object method. It takes three arguments: a host name
C<$host>, an error callback C<$on_error>, and a success callback
C<$on_success>. It tries to resolve C<$host> and, if successful, calls
C<$on_success> with a list of IP addresses (in dotted-decimal string form).
Otherwise it calls C<$on_error>.

You can call C<resolve> multiple times without problems. The callbacks will be
invoked as the results come in.

=back

=head1 SEE ALSO

L<IrssiX::Async>,
L<http://www.chiark.greenend.org.uk/~ian/adns/>.

=head1 COPYRIGHT & LICENSE

Copyright 2012 Lukas Mai.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU Lesser General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.

=cut
