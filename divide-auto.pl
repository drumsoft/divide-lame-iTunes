#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use Audio::Wav;
use Term::ProgressBar;
use YAML;
use Benchmark;

my %prefs = (
# 波形分析オプション
	threshold => -20,  # これより 有音部分/無音部分 の音量上の境界
	gaplength => 2,    # 無音部分が gaplength 以上継続したらトラックを終了しギャップとする
	ignore    => 0.5,  # ギャップ中に現れた有音部分が ignore  秒以下ならノイズと判断して無視
	wavegap   => 0.05, # トラック中に現れた無音部分が wavegap 秒以下なら波形の谷間と判断して無視
# 分割位置調整オプション
	premargin  => 0.5, # トラック開始点を見つけたら、そこから pregap 分のマージンを取る
	postmargin => 2,   # 最終トラック終了位置から postmargin 分のマージンを取る
# 出力オプション
	format     => 'time', # 'time' => 'hh:mm:ss.sss' or 'samples' => '99999s'
);

my $verbose = 0; # verbose mode (for test)

sub main {
	if ( @ARGV ) {
		foreach ( @ARGV ) {
			if ( -e $_ && -f $_ && -r $_ ) {
				my @listtime = process_main($_);
			} else {
				die "cannot read $_";
			}
		}
	} else {
		print "usage: " . __FILE__ . " target_wave_files...\n";
	}
}

sub process_main {
	my $file = $_;

	# listfile name
	my $listfile = $file;
	$listfile =~ s/\.\w+$//;
	if ( ! -e "$listfile.txt" ) {
		$listfile = "$listfile.txt";
	} else {
		my $count = 0;
		while ( -e "$listfile-$count.txt") {
			$count++;
		}
		$listfile = "$listfile-$count.txt";
	}

	my @listtime = analyze($_);

	open my $out, ">$listfile" or die "cannot open $listfile";
	my $number = 1;
	print $out "#fade 0.1\n#normalize 1\n#lameoption -b 320 -h\n\n";
	print $out "$file\tALBUM\tYEAR\tGENRE\n";
	while ( @listtime > 1 ) {
		print $out shift(@listtime) . "\t$number\t\tSONG\n";
		$number++;
	}
	print $out shift(@listtime) . "\n";
	close $out;
}

sub analyze {
	my $file = shift;
	report("Processing $file ...");

	# open Wav
	my $wavread = Audio::Wav->new()->read( $file );
	my $details = $wavread->details();

	my $sample_rate = $details->{sample_rate};
	my $sample_size = $details->{bits_sample} / 8;
	my $channels = $details->{channels};
	my $block_size = $details->{block_align};
	my $total = $details->{data_length} / $block_size;
	my $samp_max          = 1 << ($details->{bits_sample} - 1);
	my $samp_sign         = 1 << ($details->{bits_sample} - 1);
	my $samp_negativemask = $samp_max - 1;

	# set parameters
	my $threshold  = $samp_max * db2value( $prefs{threshold} );
	$threshold >>= 16;
	my $gaplength  = $prefs{gaplength} * $sample_rate;
	my $ignore     = $prefs{ignore}    * $sample_rate;
	my $wavegap    = $prefs{wavegap}   * $sample_rate;

	# the sound loop
	report("\tentering sound loop ...");
	my $state = 'gap';
	my $current_state_length = 0;
	my $current_short_length = 0;
	my $tracks = Tracks->new(
		total       => $total,
		premargin   => $prefs{premargin}  * $sample_rate,
		postmargin  => $prefs{postmargin} * $sample_rate,
	);
	my $waveloader = WaveLoader->new($file, $details->{data_start}, 128 * 1024);
	my $progress = Term::ProgressBar->new($total);
	my $processunit    = int($sample_rate / 1000);
	my $processbytes   = $processunit * $block_size;
	my $processsamples = $processunit * $channels;
	for (my $i = 0; $i < $total; $i += $processunit) {
		if ( $i % 480000 == 0 ) {
			$progress->update($i);
		}
		# get data and calculate $dynamics
		my @bytes = $waveloader->get($processbytes);
		my $dynamics = 0;
		my $byteslength = @bytes;
		for (my $c = 2; $c < $byteslength; $c += $sample_size) {
#			my $data = 0;
#			for (my $d = 0; $d < $sample_size; $d++ ) {
#				$data += $bytes[$c * $sample_size + $d] << ($d * 8);
#			}
			my $data = $bytes[$c];
			if ( $data & 0x80 ) {
				$data = 0x80 - ($data & 0x7F); #abs
			}
#			if ( $data & $samp_sign ) {
#				$data = $samp_max - ($data & $samp_negativemask); #abs
#			}
			if ( $data > $dynamics ) {
				$dynamics = $data;
			}
		}

		# change state
		$current_state_length++;
		if      ( $state eq 'gap') {
			if ( $dynamics >= $threshold ) {
				$tracks->sounds_appeared($i);
				$state = 'sound_in_gap';
				$current_state_length = 0;
			}
		} elsif ( $state eq 'sound_in_gap') {
			if ( $current_state_length >= $ignore ) {
				$tracks->appeared_sound_was_track($i);
				$state = 'track';
			} elsif ( $dynamics < $threshold ) {
				$state = 'wavegap_in_sound_in_gap';
				$current_short_length = 0;
			}
		} elsif ( $state eq 'wavegap_in_sound_in_gap') {
			$current_short_length++;
			if ( $current_state_length >= $ignore ) {
				$tracks->appeared_sound_was_track($i);
				$state = 'track';
			} elsif ( $current_short_length >= $wavegap ) {
				$tracks->appeared_sound_was_noise($i);
				$state = 'gap';
			} elsif ( $dynamics > $threshold ) {
				$state = 'sound_in_gap';
			}
		} elsif ( $state eq 'track') {
			if ( $dynamics < $threshold ) {
				$tracks->silence_appeared($i);
				$state = 'slence_in_track';
				$current_state_length = 0;
			}
		} elsif ( $state eq 'slence_in_track') {
			if ( $current_state_length >= $gaplength ) {
				$tracks->appeared_silence_was_gap($i);
				$state = 'gap';
			} elsif ( $dynamics > $threshold ) {
				$tracks->appeared_silence_was_not_gap($i);
				$state = 'track';
			}
		}
	}
	$progress->update($total);
	$waveloader->close();
	$tracks->finish();

	report("\tformatting ...");
	my $formatter;
	if ( $prefs{'format'} eq 'time' ) {
		if ( $total / $sample_rate / 3600 >= 1 ) {
			$formatter = sub {
				my $sec  = (shift) / $sample_rate;
				my $min = int( $sec / 60 );
				$sec -= 60 * $min;
				my $hour = int( $min / 60 );
				$min  = $min % 60;
				return sprintf '%02d:%02d:%02.3f', $hour, $min, $sec;
			}
		} else {
			$formatter = sub {
				my $sec  = (shift) / $sample_rate;
				my $min = int( $sec / 60 );
				$sec -= 60 * $min;
				return sprintf '%02d:%02.3f', $min, $sec;
			}
		}
	} elsif ( $prefs{'format'} eq 'samples' ) {
		$formatter = sub {
			return (shift) . 's';
		}
	}

	return map $formatter, $tracks->timelist();
}

sub report {
	print @_, "\n";
}

sub db2value($) {
	return 10 ** ((shift) / 10);
}

sub value2db($) {
	return 10 * ( log(shift) / log(10) );
}

main();

# -------------------------------------------------------------------------
package WaveLoader;

sub new {
	my $class = shift;
	my $file = shift;
	my $offset = shift;
	my $buffersize = shift || (1 * 1024 * 1024);

	my $self = bless {
		fh  => undef,
		buf => '',
		position => 0,
		length => 0,
		buffersize => $buffersize,
	}, $class;

	open my $fh, $file or die "cannot open $file";
	binmode $fh;
	seek $fh, $offset, 0;

	$self->{fh} = $fh;
	return $self;
}

sub get {
	my $self = shift;
	my $bytes = shift;
	my @bytes;

	if ( $self->{position} + $bytes > $self->{length} ) {
		my $rest = $self->{length} - $self->{position};
		if ( $rest > 0 ) {
			@bytes = unpack "C$rest", substr($self->{buf}, $self->{position}, $rest);
			$bytes -= $rest;
		}
		my $rd = read $self->{fh}, $self->{buf}, $self->{buffersize};
		$self->{length} = $rd;
		$self->{position} = 0;
	}
	push @bytes, unpack "C$bytes", substr($self->{buf}, $self->{position}, $bytes);
	$self->{position} += $bytes;
	return @bytes;
}

sub close {
	my $self = shift;
	close $self->{fh};
}

package Tracks;

sub new {
	my $class = shift;
	my $self = bless {
		tracks => [],
		state => 'gap',
		@_ # total, premargin, postmargin
	}, $class;
	return $self;
}

sub assert {
	my ($condition, $testname, $time) = @_;
	my $methodname = (caller 1)[3];
	die "Tracks: $methodname '$testname' error in time" if $condition;
}

sub sounds_appeared {
	my $self = shift;
	my $time = shift;
	assert('gap' ne $self->{state}, 'not in gap', $time);
	assert(defined $self->{temp_start}, 'double called', $time);
	$self->{temp_start} = $time;
}

sub appeared_sound_was_track {
	my $self = shift;
	my $time = shift;
	assert('gap' ne $self->{state}, 'not in gap', $time);
	assert(!defined $self->{temp_start}, 'no sounds appeared', $time);

	my $start = $self->{temp_start} - $self->{premargin};
	$start = 0 if $start < 0;
	push @{ $self->{tracks} }, $start;
	$self->{state} = 'track';
	undef $self->{temp_start};
}

sub appeared_sound_was_noise {
	my $self = shift;
	my $time = shift;
	assert('gap' ne $self->{state}, 'not in gap', $time);
	assert(!defined $self->{temp_start}, 'no sounds appeared', $time);
	undef $self->{temp_start};
}

sub silence_appeared {
	my $self = shift;
	my $time = shift;
	assert('track' ne $self->{state}, 'not in track', $time);
	assert(defined $self->{temp_end}, 'double called', $time);
	$self->{temp_end} = $time;
}

sub appeared_silence_was_gap {
	my $self = shift;
	my $time = shift;
	assert('track' ne $self->{state}, 'not in track', $time);
	assert(! defined $self->{temp_end}, 'no silence appeared', $time);

	my $end = $self->{temp_end} + $self->{postmargin};
	$end = $self->{total} if $end > $self->{total};
	$self->{state} = 'gap';
	$self->{current_end} = $end;
	undef $self->{temp_end};
}

sub appeared_silence_was_not_gap {
	my $self = shift;
	my $time = shift;
	assert('track' ne $self->{state}, 'not in track', $time);
	assert(! defined $self->{temp_end}, 'no silence appeared', $time);
	undef $self->{temp_end};
}

sub finish {
	my $self = shift;
	if ( $self->{state} eq 'track' ) {
		if ( defined $self->{temp_end} ) {
			my $end = $self->{temp_end} + $self->{postmargin};
			$end = $self->{total} if $end > $self->{total};
			$self->{current_end} = $end;
		} else {
			$self->{current_end} = $self->{total};
		}
	}
}

sub timelist {
	my $self = shift;
	return ( @{ $self->{tracks} }, $self->{current_end} );
}

1;

__END__

# $wavread->details()
bits_sample: 24
block_align: 6
bytes_sec: 288000
channels: 2
data_finish: 267866192
data_length: 267866112
data_start: 80
length: 930.090666666667
sample_rate: 48000
total_length: 267866184
wave-ex: 1


# template of Divide Setting File.

#fade 0.1
#normalize 1
#lameoption -b 320 -h

##filename	albumname	year	genre
##starttime	number	artist	songname
##finishtime
