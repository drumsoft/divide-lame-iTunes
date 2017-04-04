#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use Encode;
use MP3::Tag;

my %prefs = (
	fadein    => 0.1,
	fadeout   => 0.1,
	normalize => 0,
	album => '',
	year => '',
	genre => '',
	artist  => '',
	lameoption => '-q 0 -b 320',
);

my $do_unlink = 1; # unlink intermediate files (0 for test)
my $verbose = 0; # verbose mode (for test)

while (@ARGV) {
	if ($ARGV[0] =~ /--?no_unlink$/) {
		$do_unlink = 0;
		shift @ARGV;
	} else {
		last;
	}
}

if (@ARGV != 1) {
	print "usage: divide-lame-iTunes.pl [-no_unlink] encoding-queue.txt\n";
	exit -1;
}

sub main () {
	my $procs = parse(get_commands($ARGV[0]));

	foreach (@$procs) {
		if ($_->{'type'} eq 'normalize') {
			normalize($_->{'source'}, $_->{'destination'});
		}elsif ($_->{'type'} eq 'unlink') {
			unlink($_->{'target'}) or warn "WARNING: unlink $_->{'target'} failed." if $do_unlink;
		}elsif ($_->{'type'} eq 'track') {
			my $trimmed = trimout($_);
			my $mp3file = lamemp3($trimmed, $_->{'lameoption'});
			unlink($trimmed) or warn "WARNING: unlink $trimmed failed." if $do_unlink;
			write_mp3tags($mp3file, $_);
			mp3_addiTunes($mp3file);
		}
	}
}

sub report {
	print @_, "\n";
}

# ------------------------------------------------ audio file commands
sub normalize($$) {
	my ($src, $dst) = @_;
	report("normalize: $src") if $verbose;
	system(qq{sox "$src" "$dst" gain -n});
	die "normalize $src with sox failed." if $? >> 8;
}

sub trimout($) {
	my $trk = shift;
	my $ext = ($trk->{'source'} =~ /\.(\w+)$/) ? $1 : '';
	my $outfile = sprintf "%03d-%s.%s", $trk->{'number'}, filename($trk->{'title'}), $ext;
	my $fade = ($trk->{'fadein'} > 0 || $trk->{'fadeout'} > 0) ? 
		qq{fade $trk->{'fadein'} 0 $trk->{'fadeout'}} : '';
	report("trimout: " . $trk->{'source'}) if $verbose;
	system(qq{sox "} . $trk->{'source'} . qq{" "$outfile" trim $trk->{'start'} $trk->{'length'} $fade});
	die "trim " . $trk->{'title'} . " with sox failed." if $? >> 8;
	return $outfile;
}

sub lamemp3($) {
	my ($src, $option) = @_;
	my $dst = $src;
	$dst =~ s/\.(\w+)$/".mp3"/e;
	$dst .= ".mp3" if $dst eq $src;
	report("lamemp3 $src") if $verbose;
	system(qq{lame $option "$src" "$dst"});
	die "$src mp3 compression with lame failed." if $? >> 8;
	return $dst;
}

sub write_mp3tags($$) {
	my $tgt = shift;
	my $trk = shift;
	
	report("write_tag $tgt") if $verbose;
	MP3::Tag->new($tgt)->update_tags({
		title  => $trk->{'title'},
		artist => $trk->{'artist'},
		album  => $trk->{'album'},
		year   => $trk->{'year'},
		track  => $trk->{'number'},
		genre  => $trk->{'genre'}
	});
}

sub mp3_addiTunes($) {
	my $tgt = shift;
	report("addiTunes $tgt") if $verbose;
	system(qq{open -a iTunes -g "$tgt"});
	die "add $tgt to iTunes failed." if $? >> 8;
}

# ------------------------------------------------------------- parser functions
sub parse($) {
	my $commands = shift;
	my @procs;
	my $pre_divider;
	my $default_number = 0;
	my $temp_normalize_file;

	my $push_unlink = sub {
		if ( $temp_normalize_file ) {
			push @procs, {
				type => 'unlink',
				target => $temp_normalize_file, 
			};
			undef $temp_normalize_file;
		}
	};

	foreach(@$commands) {
		next if trim() eq '';
		if ( m{^\#\#} ) { # comment
			next;
		}elsif ( m{^\#(\w+)\s+(.*)$} ) { # macro
			# #key value
			if ($1 eq 'fade') {
				$prefs{'fadein'} = $prefs{'fadeout'} = trim($2);
			}else{
				$prefs{$1} = trim($2);
			}
		}elsif( m{^(?:[\d\:\.]+|\d+s)\s*(\t|$)} ){# divider 
			#開始点位置	トラック番号	アーティスト	曲名
			my $data = $1;
			my %temp;
			@temp{qw(start number artist title)} = map {trim($_)} split "\t", $_;
			if (defined $temp{'artist'}) {
				$temp{'artist'} =~ s/\s*\x{2013}$//;
				$temp{'artist'} =~ s/\s*\*$//;
				$temp{'artist'} =~ s/^(.*),\s*(the)$/"$2 $1"/ei;
			}
			setprefs(\%prefs, \%temp);
			if ($pre_divider) {
				$pre_divider->{'length'} = 
					timediff($prefs{'start'}, $pre_divider->{'start'});
				undef $pre_divider;
			}
			if (defined $data && '' ne $data) {
				$default_number++;
				unless (defined $temp{'number'} && $temp{'number'} =~ /^\d+$/) {
					$prefs{'number'} = $default_number;
				}
				unless (defined $temp{'title'} && $temp{'title'} ne '') {
					$prefs{'title'} = "Track $prefs{'number'}";
				}
				$pre_divider = {
					type   => 'track',
					source => $prefs{'source'},
					start  => $prefs{'start'},
					fadein => $prefs{'fadein'},
					fadeout => $prefs{'fadeout'},
					number => $prefs{'number'},
					title  => $prefs{'title'},
					artist => $prefs{'artist'},
					album  => $prefs{'album'},
					year   => $prefs{'year'},
					genre  => $prefs{'genre'},
					lameoption  => $prefs{'lameoption'},
				};
				push @procs, $pre_divider;
			}
		}else{ # file
			#ファイル名	アルバム名	年	ジャンル
			$push_unlink->();
			my %temp;
			@temp{qw(source album year genre)} = map {trim($_)} split "\t", $_;
			if (defined $temp{'album'} && $temp{'album'} ne '' && $temp{'album'} ne $prefs{'album'}) {
				$default_number = 0;
			}
			setprefs(\%prefs, \%temp);
			if ( $prefs{'normalize'} ) {
				my $tempfile = "temp-$prefs{'source'}";
				push @procs, {
					type => 'normalize',
					source => $prefs{'source'}, 
					destination => $tempfile
				};
				$prefs{'source'} = $tempfile;
				$temp_normalize_file = $tempfile;
			}
		}
	}
	$push_unlink->();

	\@procs;
}

sub timediff($$) {
	my ($a, $b) = @_;
	my $cat = "$a $b";
	if ($cat =~ /^(\d+)s (\d+)s$/) {
		my $len = $1 - $2;
		die "start time reversing: $2 -> $1" if $len < 0;
		return $len . 's';
	}elsif ($cat =~ /^[\d\:\.]+ [\d\:\.]+$/) {
		my $len = time2second($a) - time2second($b);
		die "start time reversing: $b -> $a" if $len < 0;
		return second2time( $len );
	}else{
		die "cannot diff $a and $b.";
	}
}
sub time2second {
	my $t = shift;
	my @t = split ':', $t;
	my $s = 0;
	my $unit = 1;
	while (my $u = pop @t) {
		$s += $u * $unit;
		$unit *= 60;
	}
	return $s;
}
sub second2time {
	my $s = shift;
	my @t;
	while ($s > 0) {
		my $n = int($s / 60);
		unshift @t, $s - ($n * 60);
		$s = $n;
	}
	$t[-1] = int($t[-1] * 1000 + 0.5) / 1000;
	return join ':', @t;
}

sub filename($) {
	my $str = shift;
	$str =~ s/\W/_/g;
	$str =~ s/__+/_/g;
	return $str;
}

sub setprefs($$) {
	my ($dst, $src) = @_;
	while ( my ($k, $v) = each %$src ) {
		$dst->{$k} = $v if defined $v && $v ne '';
	}
}

sub trim {
	return $_ = trim($_) if 0 == @_;
	my $s = shift;
	$s =~ s/^[\s\r\n]+//;
	$s =~ s/[\s\r\n]+$//;
	return $s;
}

sub get_commands($) {
	my $file = shift;
	if (! -e $file) {
		print "file not found: $file\n";
		exit -1;
	}
	open my $in, $file or die "cannot open $file.";
	my @commands = map {Encode::decode 'utf8', $_} <$in>;
	close $in;
	return \@commands;
}

main();

__END__

template of Divide Setting File.

#fade 0.1
#normalize 1
#lameoption -q 0 -b 320

##filename	albumname	year	genre
##starttime	number	artist	songname
##finishtime
