package Plack::Server::Coro;
use strict;
use 5.008_001;
our $VERSION = "0.01";

sub new {
    my $class = shift;
    bless { @_ }, $class;
}

sub run {
    my($self, $app) = @_;

    my $server = Plack::Server::Coro::Server->new(host => $self->{host} || '*');
    $server->{app} = $app;
    $server->run(port => $self->{port});
}


package Plack::Server::Coro::Server;
use base qw( Net::Server::Coro );

our $HasAIO = !$ENV{PLACK_NO_SENDFILE} && eval "use Coro::AIO; 1";

use HTTP::Status;
use Scalar::Util;
use List::Util qw(sum max);
use Plack::HTTPParser qw( parse_http_request );
use Plack::Middleware::ContentLength;
use constant MAX_REQUEST_SIZE => 131072;

sub process_request {
    my $self = shift;

    my $fh = $self->{server}{client};

    my $env = {
        SERVER_PORT => $self->{server}{port}[0],
        SERVER_NAME => $self->{server}{host}[0],
        SCRIPT_NAME => '',
        REMOTE_ADDR => $self->{server}{peeraddr},
        'psgi.version' => [ 1, 0 ],
        'psgi.errors'  => *STDERR,
        'psgi.input'   => $self->{server}{client},
        'psgi.url_scheme' => 'http', # SSL support?
        'psgi.nonblocking'  => Plack::Util::TRUE,
        'psgi.run_once'     => Plack::Util::FALSE,
        'psgi.multithread'  => Plack::Util::TRUE,
        'psgi.multiprocess' => Plack::Util::FALSE,
    };

    my $res = [ 400, [ 'Content-Type' => 'text/plain' ], [ 'Bad Request' ] ];

    my $buf = '';
    while (1) {
        my $read = $fh->readline("\015\012\015\012")
            or last;
        $buf .= $read;

        my $reqlen = parse_http_request($buf, $env);
        if ($reqlen >= 0) {
            my $app = Plack::Middleware::ContentLength->wrap($self->{app});
            $res = Plack::Util::run_app $app, $env;
            last;
        } elsif ($reqlen == -2) {
            # incomplete, continue
        } else {
            last;
        }
    }

    my (@lines, $conn_value);

    while (my ($k, $v) = splice(@{$res->[1]}, 0, 2)) {
        push @lines, "$k: $v\015\012";
        if (lc $k eq 'connection') {
            $conn_value = $v;
        }
    }

    unshift @lines, "HTTP/1.0 $res->[0] @{[ HTTP::Status::status_message($res->[0]) ]}\015\012";
    push @lines, "\015\012";

    $fh->syswrite(join '', @lines);

    if ($HasAIO && Plack::Util::is_real_fh($res->[2])) {
        my $length = -s $res->[2];
        my $offset = 0;
        while (1) {
            my $sent = aio_sendfile( $fh->fh, $res->[2], $offset, $length - $offset );
            $offset += $sent if $sent > 0;
            last if $offset >= $length;
        }
        return;
    }

    Plack::Util::foreach($res->[2], sub { $fh->syswrite(@_) });
}

package Plack::Server::Coro;

1;

__END__

=head1 NAME

Plack::Server::Coro - Coro cooperative multithread web server

=head1 SYNOPSIS

  plackup -i Coro

=head1 DESCRIPTION

This is a Coro based Plack web server. It uses L<Net::Server::Coro>
under the hood, which means we have coroutines (threads) for each
socket, active connections and a main loop.

Because it's Coro based your web application can actually block with
I/O wait as long as it yields when being blocked, to the other
coroutine either explicitly with C<cede> or automatically (via Coro::*
magic).

  # your web application
  use Coro::LWP;
  my $content = LWP::Simple:;get($url); # this yields to other threads when IO blocks

This server also uses L<Coro::AIO> (and L<IO::AIO>) if available, to
send the static filehandle using sendfile(2).

The simple benchmark shows this server gives 2000 requests per second
in the simple Hello World app, and 300 requests to serve 2MB photo
files when used with AIO modules. Brilliantly fast.

This web server sets C<psgi.multithread> env var on.

=head1 AUTHOR

Tatsuhiko Miyagawa

=head1 LICENSE

This module is licensed under the same terms as Perl itself.

=head1 SEE ALSO

L<Coro> L<Net::Server::Coro> L<Coro::AIO>

=cut
