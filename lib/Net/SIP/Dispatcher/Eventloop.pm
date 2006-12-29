
###########################################################################
# package Net::SIP::Dispatcher::Eventloop
###########################################################################

use strict;
use warnings;

package Net::SIP::Dispatcher::Eventloop;
use fields qw( fd timer now );
use Time::HiRes qw(gettimeofday);
use Socket;
use List::Util qw(first);
use Net::SIP::Util 'invoke_callback';
use Net::SIP::Debug;

###########################################################################
sub new {
	my $class = shift;
	my $self = fields::new($class);
	%$self = (
		fd => [],
		timer => [],
		now => scalar(gettimeofday()),
	);
	return $self;
}

sub addFD {
	my Net::SIP::Dispatcher::Eventloop $self = shift;
	my ($fd,$callback) = @_;
	defined( my $fn = fileno($fd)) || return;
	DEBUG( "$self added fn=$fn sock=".eval { my ($port,$addr) = unpack_sockaddr_in( getsockname($fd)); inet_ntoa($addr).':'.$port } );
	$self->{fd}[$fn] = [ $fd,$callback ];
}

sub delFD {
	my Net::SIP::Dispatcher::Eventloop $self = shift;
	my ($fd) = @_;
	defined( my $fn = fileno($fd)) || return;
	DEBUG( "$self delete fn=$fn sock=".eval { my ($port,$addr) = unpack_sockaddr_in( getsockname($fd)); inet_ntoa($addr).':'.$port } );
	delete $self->{fd}[$fn];
}

sub addTimer {
	my Net::SIP::Dispatcher::Eventloop $self = shift;
	my ($when,$callback,$repeat ) = @_;
	$when += $self->{now} if $when < 3600*24*365;
		
	my $timer = Net::SIP::Dispatcher::Eventloop::TimerEvent->new( $when, $repeat, $callback );
	push @{ $self->{timer}}, $timer;
	return $timer;
}

sub looptime {
	my Net::SIP::Dispatcher::Eventloop $self = shift;
	return $self->{now}
}


###########################################################################
# simple mainloop
# Args: ($self;$timeout,@stop)
#  $timeout: if 0 just poll once, if undef never return, otherwise return
#    after $timeout seconds
#  @stop: \@array of Scalar-REF, if one gets true the eventloop will be stopped
# Returns: NONE
###########################################################################
sub loop {
	my Net::SIP::Dispatcher::Eventloop $self = shift;
	my ($timeout,@stop) = @_;

	# looptime for this run
	my $looptime = $self->{now} = gettimeofday();

	# if timeout defined and != 0 set $end to now+timeout
	# otherwise set end to undef|0 depending on timeout
	my $end = $timeout ? $looptime + $timeout : $timeout;
	my $to = $timeout;

	while ( !$to || $to>0 ) {

		DEBUG( "timeout = ".( defined($to) ? $to: '<undef>' ));
		# handle timers
		my $timer = $self->{timer};

		my $do_timer = 1;
		while ( @$timer && $do_timer ) {
			$do_timer = 0;
			@$timer = sort { $a->{expire} <=> $b->{expire} } @$timer;

			# delete canceled timers
			shift(@$timer) while ( @$timer && !$timer->[0]{expire} );

			# run expired timers
			while ( @$timer && $timer->[0]{expire} <= $looptime ) {
				my $t = shift(@$timer);
				DEBUG( "trigger timer %s repeat=%s",$t->{expire} || '<undef>', $t->{repeat} || '<undef>' );
				if ( $t->{repeat} ) {
					$t->{expire} += $t->{repeat};
					DEBUG( "timer gets repeated at $t->{expire}" );
					push @$timer,$t;
					$do_timer = 1; # rerun loop
				}
				invoke_callback( $t->{callback},$t );
			}
		}

		# adjust timeout for select based on when next timer expires
		if ( @$timer ) {
			my $next_timer = $timer->[0]{expire} - $looptime;
			$to = $next_timer if !defined($to) || $to>$next_timer;
		}
		DEBUG( "timeout = ".( defined($to) ? $to: '<undef>' ));

		if ( grep { ${$_} } @stop ) {
			DEBUG( "stopvar triggered" );
			return;
		}
		
		# wait for selected fds
		my $fds = $self->{fd};
		my $rin;
		if ( my @to_read = grep { $_ } @$fds ) {

			# Select which fds are readable or timeout
			my $rin = '';
			map { vec( $rin,fileno($_->[0]),1 ) = 1 } @to_read;
			DEBUG( "$self handles=".join( " ",map { fileno($_->[0]) } @to_read ));
			die $! if select( my $rout = $rin,undef,undef,$to ) < 0;
			my @can_read = grep { vec($rout,fileno($_->[0]),1) } @to_read;
			DEBUG( "$self can_read=".join( " ",map { fileno($_->[0]) } @can_read ));

			# returned from select
			$looptime = $self->{now} = gettimeofday();

			foreach my $fd_data (@can_read) {
				invoke_callback( $fd_data->[1],$fd_data->[0] );
			}
		} else {
			DEBUG( "no handles, sleeping for %s", defined($to) ? $to : '<endless>' );
			select(undef,undef,undef,$to )
		}

		if ( defined($timeout)) {
			last if !$timeout;
			$to = $end - $looptime;
		} else {
			$to = undef
		}
	}
}


###########################################################################
package Net::SIP::Dispatcher::Eventloop::TimerEvent;
use fields qw( expire repeat callback );
sub new {
	my ($class,$expire,$repeat,$callback) = @_;
	my $self = fields::new( $class );
	%$self = ( expire => $expire, repeat => $repeat, callback => $callback );
	return $self;
}

sub cancel {
	my Net::SIP::Dispatcher::Eventloop::TimerEvent $self = shift;
	$self->{expire} = 0;
}

1;
