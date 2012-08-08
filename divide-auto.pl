#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use Audio::Wav;
use YAML;
use Inline 'C';

my %prefs = (
# 波形分析オプション
	precision => 4000, # 分析精度 1/precision 秒単位で分析を行う
	threshold => -22,  # 有音部分/無音部分 音量の境界
	gaplength => 1,    # 無音部分が gaplength 以上継続したらトラックを終了しギャップとする
	ignore    => 1.18, # ギャップ中に現れた有音部分が ignore  秒以下ならノイズと判断して無視
	wavegap   => 0.03, # トラック中に現れた無音部分が wavegap 秒以下なら波形の谷間と判断して無視
# 分割位置調整オプション
	premargin  => 0.5, # トラック開始点を見つけたら、そこから pregap 分のマージンを取る
	postmargin => 2,   # トラック終了位置から postmargin 分のマージンを取る
# 出力オプション
	format     => 'time', # 'time' => 'hh:mm:ss.sss' or 'samples' => '99999s'
);

my $verbose = 1; # verbose mode
my $debug = 1; # debug mode

sub main {
	if ( @ARGV ) {
		if ( @ARGV == 2 && -f $ARGV[0] && $ARGV[1] =~ /^\d+$/ ) {
			play($ARGV[0], $ARGV[1]);
		} else {
			foreach ( @ARGV ) {
				if ( -e $_ && -f $_ && -r $_ ) {
					my @listtime = process_main($_);
				} else {
					die "cannot read $_";
				}
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
	print $out "#fade 0.1\n#normalize 1\n#lameoption -b 320 -h\n\n";
	print $out "$file\tALBUM\tYEAR\tGENRE\n";
	for ( my $number = 0; $number < @listtime - 1; $number++ ) {
		printf $out "\t$number\t\tSONG\n", $number+1, $listtime[$number];
	}
	print $out $listtime[-1] . "\n";
	close $out;
}

sub analyze {
	my $file = shift;
	report("Processing $file ...");

	# open Wav
	my $wavread = Audio::Wav->new()->read( $file );
	my $details = $wavread->details();

	my $sample_rate = $details->{sample_rate};
	my $total = $details->{data_length} / $details->{block_align};
	my $premargin  = $prefs{premargin}  * $sample_rate;
	my $postmargin = $prefs{postmargin} * $sample_rate;

	my @result = analyze_c2( $file, $details->{data_start}, $total, 
		$prefs{precision}, 
		$details->{sample_rate}, $details->{bits_sample} / 8, $details->{channels}, 
		db2value( $prefs{threshold} ), 
		$prefs{gaplength} * $sample_rate, 
		$prefs{ignore} * $sample_rate, 
		$prefs{wavegap} * $sample_rate);

	my $formatter;
	if ( $prefs{'format'} eq 'time' ) {
		if ( $total / $sample_rate / 3600 >= 1 ) {
			$formatter = sub {
				my $sec  = (shift || $_) / $sample_rate;
				my $min = int( $sec / 60 );
				$sec -= 60 * $min;
				my $hour = int( $min / 60 );
				$min  = $min % 60;
				return sprintf '%02d:%02d:%02.3f', $hour, $min, $sec;
			}
		} else {
			$formatter = sub {
				my $sec  = (shift || $_) / $sample_rate;
				my $min = int( $sec / 60 );
				$sec -= 60 * $min;
				return sprintf '%02d:%02.3f', $min, $sec;
			}
		}
	} elsif ( $prefs{'format'} eq 'samples' ) {
		$formatter = sub {
			return (shift || $_) . 's';
		}
	}

	report(sprintf "\t[detected positions] total length: %s", $formatter->($total) ) if $verbose;
	my @positions;
	my $number = 0;
	for ( my $i = 0; $i < @result; $i += 2 ) {
		$number++;
		report(sprintf "\ttrack %d: from %s to %s", $number, 
		       $formatter->($result[$i]), $formatter->($result[$i+1]) ) if $verbose;
		my $start = $result[$i] - $premargin;
		push @positions, ( $start > 0 ? $start : 0 );
	}
	my $end = $result[-1] + $postmargin;
	push @positions, ( $end < $total ? $end : $total );

	return map &$formatter, @positions;
}


sub play {
	my $file = shift;
	my $number =shift;
	
	if ( $file !~ /\.txt$/ ) {
		$file = get_txt_file($file);
	}
	report("divide file: $file");
	
	my @list = get_startlist($file);

	print YAML::Dump(@list);
	my $wavfile = shift @list;
	my $command = sprintf "play '%s' trim %s", $wavfile, $list[$number - 1];
	report($command);
	system $command;
}

sub get_txt_file {
	my $listfile = shift;

	$listfile =~ s/\.\w+$/.txt/;
	if ( -e $listfile ) {
		my $count = 0;
		while ( -e "$listfile-$count.txt") {
			$listfile = "$listfile-$count.txt";
			$count++;
		}
	}
	return $listfile;
}

sub get_startlist {
	my $listfile = shift;
	open my($in), $listfile;
	my @tokens = 
		grep { /^[^\#]/ } 
		map { chomp; s/^[\s\t]+//; (split /\t/)[0] } <$in>;
	close $listfile;

	my @list = grep { /^\d+s$/ || /^[\d\:\.]+$/ } @tokens;
	my $wavfile = (grep { /\.\w+$/ } @tokens)[0];
	return ($wavfile, @list);
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


__C__
#define STATE_GAP                                   0
#define STATE_SOUND_IN_GAP                          1
#define STATE_WAVEGAP_IN_SOUND_IN_GAP               2
#define STATE_TRACK                                 3
#define STATE_WAVEGAP_IN_TRACK                      4
#define STATE_SILENCE_IN_TRACK                      5
#define STATE_SOUND_IN_SILENCE_IN_TRACK             6
#define STATE_WAVEGAP_IN_SOUND_IN_SILENCE_IN_TRACK  7

/*
	analyze_c returns (start1, end1, start2, end2, ...)
*/
void analyze_c( char* file, int offset, int total, 
	int precision, 
	int sample_rate, int sample_size, int channels, 
	double threshold_f, 
	int gaplength, int ignore, int wavegap ) {

	Inline_Stack_Vars;
	Inline_Stack_Reset;

	int threshold = (int)((double)0x7fffffff * threshold_f);
	int processunit = sample_rate / precision;
	if ( processunit < 1 ) processunit = 1;
	int processsize = processunit * channels * sample_size;
	int state = STATE_GAP;
	int length_sound, length_wavegap, length_silence;
	int bitoffset = 8 * (4 - sample_size);

	unsigned char *buffer = (unsigned char*) malloc(processsize);
	int fd = open (file, O_RDONLY);
	lseek( fd, offset, SEEK_SET );

	int position, c, d;
	for (position = 0; position < total; position += processunit) {
		// get data and calculate $dynamics
		int rd = read( fd, buffer, processsize );
		int dynamics = 0;
		for (c = 0; c < rd; c += sample_size) {
			int data = 0;
			for (d = 0; d < sample_size; d++ ) {
				data |= buffer[c + d] << (8 * d + bitoffset);
			}
			if ( abs(data) > dynamics ) {
				dynamics = abs(data);
			}
		}

		// change state
		if        ( state == STATE_GAP) {
			if ( dynamics >= threshold ) {
				state = STATE_SOUND_IN_GAP;
				length_sound = 0;
			}
		} else if ( state == STATE_SOUND_IN_GAP) {
			length_sound += processunit;
			if ( length_sound >= ignore ) {
				state = STATE_TRACK;
				Inline_Stack_Push(newSViv( position - length_sound ));
			} else if ( dynamics < threshold ) {
				state = STATE_WAVEGAP_IN_SOUND_IN_GAP;
				length_wavegap = 0;
			}
		} else if ( state == STATE_WAVEGAP_IN_SOUND_IN_GAP) {
			length_wavegap += processunit;
			length_sound += processunit;
			if ( length_sound >= ignore ) {
				state = STATE_TRACK;
				Inline_Stack_Push(newSViv( position - length_sound ));
			} else if ( length_wavegap >= wavegap ) {
				state = STATE_GAP;
			} else if ( dynamics > threshold ) {
				state = STATE_SOUND_IN_GAP;
			}

		} else if ( state == STATE_TRACK) {
			if ( dynamics < threshold ) {
				state = STATE_WAVEGAP_IN_TRACK;
				length_silence = 0;
				length_wavegap = 0;
			}
		} else if ( state == STATE_WAVEGAP_IN_TRACK) {
			length_wavegap += processunit;
			length_silence += processunit;
			if ( length_wavegap > wavegap ) {
				state = STATE_SILENCE_IN_TRACK;
			} else if ( dynamics > threshold ) {
				state = STATE_TRACK;
			}
		} else if ( state == STATE_SILENCE_IN_TRACK) {
			length_silence += processunit;
			if ( length_silence > gaplength ) {
				state = STATE_GAP;
				Inline_Stack_Push(newSViv( position - length_silence ));
			} else if ( dynamics > threshold ) {
				state = STATE_SOUND_IN_SILENCE_IN_TRACK;
				length_sound = 0;
			}
		} else if ( state == STATE_SOUND_IN_SILENCE_IN_TRACK) {
			length_silence += processunit;
			length_sound   += processunit;
			if ( length_silence > gaplength ) {
				state = STATE_GAP;
				Inline_Stack_Push(newSViv( position - length_silence ));
			} else if ( length_sound > ignore ) {
				state = STATE_TRACK;
			} else if ( dynamics < threshold ) {
				state = STATE_WAVEGAP_IN_SOUND_IN_SILENCE_IN_TRACK;
				length_wavegap = 0;
			}
		} else if ( state == STATE_WAVEGAP_IN_SOUND_IN_SILENCE_IN_TRACK) {
			length_silence += processunit;
			length_sound   += processunit;
			length_wavegap += processunit;
			if ( length_silence > gaplength ) {
				state = STATE_GAP;
				Inline_Stack_Push(newSViv( position - length_silence ));
			} else if ( length_sound > ignore ) {
				state = STATE_TRACK;
			} else if ( length_wavegap > wavegap ) {
				state = STATE_SILENCE_IN_TRACK;
			} else if ( dynamics > threshold ) {
				state = STATE_SOUND_IN_SILENCE_IN_TRACK;
			}
		}
	}
	close(fd);
	free(buffer);

	if        ( state == STATE_TRACK) {
		Inline_Stack_Push(newSViv( total ));
	} else if ( state == STATE_WAVEGAP_IN_TRACK || 
	            state == STATE_SILENCE_IN_TRACK || 
	            state == STATE_SOUND_IN_SILENCE_IN_TRACK || 
	            state == STATE_WAVEGAP_IN_SOUND_IN_SILENCE_IN_TRACK) {
		Inline_Stack_Push(newSViv( position - length_silence ));
	}
	Inline_Stack_Done;
}



void analyze_c2( char* file, int offset, int total, 
	int precision, 
	int sample_rate, int sample_size, int channels, 
	double threshold_f, 
	int gaplength, int ignore, int wavegap ) {

	Inline_Stack_Vars;
	Inline_Stack_Reset;

	int threshold = (int)((double)0x7fffffff * threshold_f);
	int processunit = sample_rate / precision;
	if ( processunit < 1 ) processunit = 1;
	int processsize = processunit * channels * sample_size;
	int state = STATE_GAP;
	int length_sound, length_silence;
	int bitoffset = 8 * (4 - sample_size);

	int flyer_release  = 1 * sample_rate;
	int flyer_dropunit = flyer_release / processunit;
	int flyer_dropspeed;
	int flyer = 0;

	unsigned char *buffer = (unsigned char*) malloc(processsize);
	int fd = open (file, O_RDONLY);
	lseek( fd, offset, SEEK_SET );

	int position, c, d;
	for (position = 0; position < total; position += processunit) {
		// get data and calculate $dynamics
		int rd = read( fd, buffer, processsize );
		int dynamics = 0;
		for (c = 0; c < rd; c += sample_size) {
			int data = 0;
			for (d = 0; d < sample_size; d++ ) {
				data |= buffer[c + d] << (8 * d + bitoffset);
			}
			if ( abs(data) > dynamics ) {
				dynamics = abs(data);
			}
		}

		if ( (flyer - flyer_dropspeed) <= dynamics ) {
			flyer = dynamics;
			flyer_dropspeed = dynamics / flyer_dropunit;
		} else {
			flyer -= flyer_dropspeed;
			if ( flyer < 0 ) flyer = 0;
		}

		// change state
		if        ( state == STATE_GAP) {
			if ( flyer >= threshold ) {
				state = STATE_SOUND_IN_GAP;
				length_sound = 0;
			}
		} else if ( state == STATE_SOUND_IN_GAP) {
			length_sound += processunit;
			if ( length_sound >= ignore ) {
				state = STATE_TRACK;
				Inline_Stack_Push(newSViv( position - length_sound ));
			} else if ( flyer < threshold ) {
				state = STATE_GAP;
			}

		} else if ( state == STATE_TRACK) {
			if ( flyer < threshold ) {
				state = STATE_SILENCE_IN_TRACK;
				length_silence = 0;
			}
		} else if ( state == STATE_SILENCE_IN_TRACK) {
			length_silence += processunit;
			if ( length_silence > gaplength ) {
				state = STATE_GAP;
				Inline_Stack_Push(newSViv( position - length_silence ));
			} else if ( flyer > threshold ) {
				state = STATE_SOUND_IN_SILENCE_IN_TRACK;
				length_sound = 0;
			}
		} else if ( state == STATE_SOUND_IN_SILENCE_IN_TRACK) {
			length_silence += processunit;
			length_sound   += processunit;
			if ( length_silence > gaplength ) {
				state = STATE_GAP;
				Inline_Stack_Push(newSViv( position - length_silence ));
			} else if ( length_sound > ignore ) {
				state = STATE_TRACK;
			} else if ( flyer < threshold ) {
				state = STATE_SILENCE_IN_TRACK;
			}
		}
	}
	close(fd);
	free(buffer);

	if        ( state == STATE_TRACK) {
		Inline_Stack_Push(newSViv( total ));
	} else if ( state == STATE_SILENCE_IN_TRACK || 
	            state == STATE_SOUND_IN_SILENCE_IN_TRACK ) {
		Inline_Stack_Push(newSViv( position - length_silence ));
	}
	Inline_Stack_Done;
}


