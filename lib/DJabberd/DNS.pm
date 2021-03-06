package DJabberd::DNS;
use strict;
use base 'Danga::Socket';
use fields (
            'hostname',
            'callback',
            'srv',
            'port',
            'type',
            'recurse_count',
            'became_readable',  # bool
            'timed_out',        # bool
            );
use Carp qw(croak);

use DJabberd::Log;
our $logger = DJabberd::Log->get_logger();

use Net::DNS;
my $resolver    = Net::DNS::Resolver->new;

sub srv {
    my ($class, %opts) = @_;

    foreach (qw(callback domain service)) {
        croak("No '$_' field") unless $opts{$_};
    }

    my $hostname = delete $opts{'domain'};
    my $callback = delete $opts{'callback'};
    my $service  = delete $opts{'service'};
    my $port     = delete $opts{'port'};
    my $recurse_count = delete($opts{'recurse_count'}) || 0;
    croak "unknown opts" if %opts;

    # default port for s2s
    $port ||= 5269 if $service eq "_xmpp-server._tcp";
    croak("No specified 'port'") unless $port;

    # testing support
    if ($service eq "_xmpp-server._tcp") {
        my $endpt = DJabberd->fake_s2s_peer($hostname);
        if ($endpt) {
            $callback->($endpt);
            return;
        }
    }

    my $try_a = sub {
        my @values = @_;
        return $callback->(@values) if @values;
        $logger->debug("DNS socket for 'srv' had nothing, falling back to 'a' lookup");
        DJabberd::DNS->new(
            hostname => $hostname,
            port     => $port,
            callback => $callback,
        );
    };

    my $gafyd = sub {
        my @values = @_;
        return $callback->(@values) if @values;
        DJabberd::DNS->resolve(
            type     => "MX",
            domain   => $hostname,
            port     => $port,
            callback => sub {
                # If we get nothing, fall back to the A lookup
                return $try_a->() unless grep {$_->name eq "aspmx.l.google.com"} @_;
                # Otherwise, reprise on gmail.com
                $logger->debug("Has a GAFYD MX, trying gtalk's server");
                return DJabberd::DNS->srv(
                    domain   => "gmail.com",
                    service  => $service,
                    port     => $port,
                    callback => $callback,
                );
            }
        );
    };

    $class->resolve(
        type     => 'SRV',
        domain   => "$service.$hostname",
        callback => $DJabberd::GAFYD ? $gafyd : $try_a,
        port     => $port,
    );
}

sub new {
    my ($class, %opts) = @_;

    foreach (qw(hostname callback port)) {
        croak("No '$_' field") unless $opts{$_};
    }

    my $hostname = delete $opts{'hostname'};
    my $callback = delete $opts{'callback'};
    my $port     = delete $opts{'port'};
    my $recurse_count = delete($opts{'recurse_count'}) || 0;
    croak "unknown opts" if %opts;

    if ($hostname =~/^\d+\.\d+\.\d+\.\d+$/) {
        # we already have the IP, lets not looking it up
        $logger->debug("Skipping lookup for '$hostname', it is already the IP");
        $callback->(DJabberd::IPEndPoint->new($hostname, $port));
        return;
    }

    $class->resolve(
        type     => 'A',
        domain   => $hostname,
        callback => $callback,
        port     => $port,
    );
}

sub resolve {
    my ($class, %opts) = @_;

    foreach (qw(callback domain type port)) {
        croak("No '$_' field") unless $opts{$_};
    }

    my $hostname = delete $opts{'domain'};
    my $callback = delete $opts{'callback'};
    my $type     = delete $opts{'type'};
    my $port     = delete $opts{'port'};
    my $recurse_count = delete($opts{'recurse_count'}) || 0;
    croak "unknown opts" if %opts;

    my $method = "event_read_" . lc $type;
    croak "unknown type $type" unless $class->can($method);

    my $pkt = Net::DNS::Packet->new($hostname, $type, "IN");

    $logger->debug("pkt = $pkt");
    my $sock = $resolver->bgsend($pkt);
    $logger->debug("sock = $sock");
    my $self = $class->SUPER::new($sock);

    $self->{hostname} = $hostname;
    $self->{callback} = $callback;
    $self->{port}     = $port;
    $self->{type}     = $type;
    $self->{recurse_count} = $recurse_count;

    $self->{became_readable} = 0;
    $self->{timed_out}       = 0;

    # TODO: make DNS timeout configurable
    Danga::Socket->AddTimer(5.0, sub {
        return if $self->{became_readable};
        $self->{timed_out} = 1;
        $logger->debug("DNS '$type' lookup for '$hostname' timed out");
        $callback->();
        $self->close;
    });

    $self->watch_read(1);
}

# TODO: verify response is for correct thing?  or maybe Net::DNS does that?
# TODO: lots of other stuff.
sub event_read {
    my $self = shift;

    if ($self->{timed_out}) {
        $self->close;
        return;
    }
    $self->{became_readable} = 1;

    $logger->debug("DNS socket $self->{sock} became readable for '$self->{type}'");

    my $method = "event_read_" . lc $self->{type};
    return $self->$method;
}

sub read_packets {
    my $self = shift;
    return $resolver->bgread($self->{sock})->answer;
}

sub event_read_a {
    my $self = shift;

    my $cb = $self->{callback};
    my @ans = $self->read_packets;

    for my $ans (@ans) {
        my $rv = eval {
            if ($ans->isa('Net::DNS::RR::CNAME')) {
                if ($self->{recurse_count} < 5) {
                    $self->close;
                    DJabberd::DNS->new(hostname => $ans->cname,
                                       port     => $self->{port},
                                       callback => $cb,
                                       recurse_count => $self->{recurse_count}+1);
                }
                else {
                    # Too much recursion
                    $logger->warn("Too much CNAME recursion while resolving ".$self->{hostname});
                    $self->close;
                    $cb->();
                }
            } elsif ($ans->isa("Net::DNS::RR::PTR")) {
                $logger->debug("Ignoring RR response for $self->{hostname}");
            }
            else {
                $cb->(DJabberd::IPEndPoint->new($ans->address, $self->{port}, $self->{hostname}));
            }
            $self->close;
            1;
        };
        if ($@) {
            $self->close;
            die "ERROR in DNS world: [$@]\n";
        }
        return if $rv;
    }

    # no result
    $self->close;
    $cb->();
}

sub event_read_srv {
    my $self = shift;

    my $cb = $self->{callback};
    my @ans = $self->read_packets;

    # FIXME: Should nominally do weighted random choice beteen records
    # with lowest priority, not just choose the highest weighted.  See
    # RFC 2782.
    my @targets = sort {
        $a->priority <=> $b->priority ||
        $b->weight   <=> $a->weight
    } grep { ref $_ eq "Net::DNS::RR::SRV" && $_->port } @ans;

    $self->close;

    return $cb->() unless @targets;

    # FIXME:  we only do the first target now.  should do a chain.
    $logger->debug("DNS socket for 'srv' found stuff, now doing hostname lookup on " . $targets[0]->target);
    DJabberd::DNS->new(hostname => $targets[0]->target,
                       port     => $targets[0]->port,
                       callback => $cb);
}

sub event_read_mx {
    my $self = shift;

    my $cb = $self->{callback};
    my @ans = $self->read_packets;

    my @targets = sort {
        $a->preference <=> $b->preference
    } grep { ref $_ eq "Net::DNS::RR::MX" } @ans;

    $self->close;

    return $cb->() unless @targets;

    # FIXME:  we only do the first target now.  should do a chain.
    $logger->debug("DNS socket for 'MX' found stuff, now doing hostname lookup on " . $targets[0]->exchange);
    DJabberd::DNS->new(hostname => $targets[0]->exchange,
                       port     => $self->{port},
                       callback => $cb);
}

package DJabberd::IPEndPoint;
sub new {
    my ($class, $addr, $port, $name) = @_;
    if (defined $name) {
        $name = lc $name;
        $name =~ s/\.$//;
    }
    return bless { addr => $addr, port => $port, name => $name };
}

sub name { $_[0]{name} }
sub addr { $_[0]{addr} }
sub port { $_[0]{port} }

1;
