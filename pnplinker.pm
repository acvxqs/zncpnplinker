use strict;
use warnings;
use diagnostics;
use utf8;

use Data::Munge;
use HTTP::Response;
use JSON;

package pnplinker;
use base 'ZNC::Module';

sub description {
	"ZNC PNP-Linker bot"
}

sub module_types {
	$ZNC::CModInfo::NetworkModule
}

sub put_chan {
	my ($self, $chan, $msg) = @_;
	$self->PutIRC("PRIVMSG $chan :$msg");
}

sub OnChanMsg {
	my ($self, $nick, $chan, $what) = @_;

	$nick = $nick->GetNick;
	$chan = $chan->GetName;

	return $ZNC::CONTINUE if $chan ne '#peace&protection';

	my $now = time;
	while (my ($key, $value) = each %{$self->{last}}) {
		delete $self->{last}{$key} if $value->{t} + 3600 < $now; # 1 hour
	}
	my $thiskey = "$nick $chan ".$self->GetNetwork->GetName;
	my $regexError;
	if (my ($sep, $old, $new, $flags) = $what =~ /^
			s
			([\/`~!#%&]) # separator
			((?:(?!\1).|\\\1)+)
			\1
			((?:(?!\1).|\\\1)*)
			(?:
				\1
				(\w*) # flags
			)?
			$/x) {
		if (exists $self->{last}{$thiskey}) {
			my ($g, $i);
			$g = 'g' if $flags =~ /g/; $flags =~ s/g//g;
			$i = 'i' if $flags =~ /i/; $flags =~ s/i//g;
			if ($flags) {
				$self->put_chan($chan, "Supported regex flags: g, i. Flags “$flags” are unknown.");
				$regexError = 1;
			} else {
				my $str = $self->{last}{$thiskey}{msg};
				eval {
					my $re;
					if ($i) {
						$re = qr/$old/i;
					} else {
						$re = qr/$old/;
					}
					$what = Data::Munge::replace($str, $re, $new, $g);
					$self->put_chan($chan, "$nick meant: “$what”") if $what ne $str;
				};
				if ($@) {
					print $@;
					my $error = "$@";
					$error =~ s# at [/.\w]+ line \d+\.$##;
					$self->put_chan($chan, $error);
					$regexError = 1;
				}
			}
		}
	}
	$self->{last}{$thiskey} = {
		msg => $what,
		t => $now,
	} unless $regexError;

	if ($what eq '!install') {
		$self->put_chan($chan=>'Installing PnP: https://github.com/Peace-and-Protection/Peace-and-Protection/wiki/Installation');
	}
	if ($what eq '!wiki') {
		$self->put_chan($chan=>'Wiki: https://github.com/Peace-and-Protection/Peace-and-Protection/wiki/');
	}
	my $count = 0;
	my @wiki;
	for(my ($w,$q,$foo)=($what,'','');($q,$foo,$w)=$w=~/.*?\[\[([^\]\|]*)(\|[^\]]*)?\]\](.*)/ and $count++<4;){
		$q=~s/ /_/g;
		$q=~s/\003\d{0,2}(,\d{0,2})?//g;#color
		$q=~s/[\x{2}\x{f}\x{16}\x{1f}]//g;
		$q=~s/[\r\n]//g;
		push @wiki, "https://github.com/Peace-and-Protection/Peace-and-Protection/wiki/$q";
	}

	if (@wiki) {
		my $wikis = join(' ', @wiki);
		$self->put_chan($chan=>$wikis);
	}

	if ($what=~/(?:any|some)\s*(?:one|body)\s+(?:alive|around|awake|here|home|in|round|there)\s*(?:\?|$)/i) {
		$self->put_chan($chan=>"Pointless question detected! $nick, we are not telepaths, please ask a concrete question and wait for an answer.");
	}
	if (my ($issue) = $what=~m@(?|\B#(\d{1,})|https://github.com/Peace-and-Protection/Peace-and-Protection/(?:issues|pull)/(\d+))@) {
		if ($issue > 0) {
			$self->CreateSocket('pnplinker::github', $issue, $self->GetNetwork, $chan);
		}
	}

	return $ZNC::CONTINUE;
}

package pnplinker::github;
use base 'ZNC::Socket';

sub Init {
	my $self = shift;
	$self->{issue} = shift;
	$self->{network} = shift;
	$self->{chan} = shift;
	$self->{response} = '';
	$self->DisableReadLine;
	$self->Connect('api.github.com', 443, ssl=>1);
	$self->Write("GET https://api.github.com/repos/Peace-and-Protection/Peace-and-Protection/issues/$self->{issue} HTTP/1.0\r\n");
	$self->Write("User-Agent: https://github.com/acvxqs/zncpnplinker\r\n");
	$self->Write("Host: api.github.com\r\n");
	$self->Write("\r\n");
}

sub OnReadData {
	my $self = shift;
	my $data = shift;
	print "new data |$data|\n";
	$self->{response} .= $data;
}

sub OnDisconnected {
	my $self = shift;
	my $response = HTTP::Response->parse($self->{response});
	if ($response->is_success) {
		my $data = JSON->new->utf8->decode($response->decoded_content);
		$self->{network}->PutIRC("PRIVMSG $self->{chan} :$data->{html_url} “$data->{title}” ($data->{state})");
	} else {
		my $error = $response->status_line;
		$self->{network}->PutIRC("PRIVMSG $self->{chan} :https://github.com/Peace-and-Protection/Peace-and-Protection/issues/$self->{issue} – $error");
	}
}

sub OnTimeout {
	my $self = shift;
	$self->{network}->PutIRC("PRIVMSG $self->{chan} :github timeout");
}

sub OnConnectionRefused {
	my $self = shift;
	$self->{network}->PutIRC("PRIVMSG $self->{chan} :github connection refused");
}

1;
