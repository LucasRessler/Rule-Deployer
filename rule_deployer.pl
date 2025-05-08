use strict;
use warnings;
use diagnostics;

package Utils;

sub format_error {
    my (undef, %args) = @_;
    my $message = $args{message} // "General Error";
    if ($args{cause}) { $message .= "\n| Caused by: " . (join "\n| ", (split "\n", $args{cause})) }
    for my $hint (@{$args{hints}}) { $message .= "\n| ->> " . (join "\n|     ", (split "\n", $hint)) }
    return $message;
}

sub align_with_words {
    my (undef, $string, $pointer) = @_;
    my @parts = split " ", $string;
    for (my $i = 0; $i < scalar @parts; $i++) {
        my $len = length($parts[$i]);
        unless ($len) { next; }
        unless ($parts[$i] =~ /\w/) { $parts[$i] = " " x $len; next; }
        $parts[$i] = " " x ($len - int($len / 2) - 1) . ($pointer // " ") . " " x int($len / 2);
    }
    return join " ", @parts;
}


package Ansi;

use constant {
    Reset  => "\e[0m",
    Red    => "\e[31m",
    Green  => "\e[32m",
    Yellow => "\e[33m",
    Cyan   => "\e[36m"
};


package LogLevel;

use constant {
    Debug => 0,
    Info  => 1,
    Warn  => 2,
    Error => 3,
};

sub to_string_equal {
    my $level = $_[1];
    my %strs = (
        LogLevel->Debug => "DEBUG",
        LogLevel->Info  => "INFO ",
        LogLevel->Warn  => "WARN ",
        LogLevel->Error => "ERROR",
    );
    return $strs{$level} // " --- ";
}

sub to_print_prefix {
    my $level = $_[1];
    my %strs = (
        LogLevel->Debug => Ansi->Cyan   . "DEBUG: "   . Ansi->Reset,
        LogLevel->Warn  => Ansi->Yellow . "WARNING: " . Ansi->Reset,
        LogLevel->Error => Ansi->Red    . "ERROR: "   . Ansi->Reset,
    );
    return $strs{$level} // "";
}


package Logger;

use Time::Piece;
use Time::HiRes qw(gettimeofday);

sub new {
    my ($class, %args) = @_;
    my $self = {
        logs => [],
        section => $args{section} // "",
        min_llv => $args{min_llv} // LogLevel->Info,
    };

    bless $self, $class;
    return $self;
}

sub set_section {
    my ($self, $section) = @_;
    $self->{section} = $section;
}

sub log {
    my ($self, $message, $level) = @_;
    my ($seconds, $micros) = gettimeofday();
    $message =~ s/^\s+|\s+$//g;
    push @{$self->{logs}}, {
        level   => $level,
        message => $message,
        section => $self->{section},
        date_s  => $seconds,
        date_m  => $micros,
    };
    unless ($level < $self->{min_llv}) {
        print LogLevel->to_print_prefix($level), "$message\n";
    }
    return $self->{logs}->[-1];
}

sub debug { $_[0]->log($_[1], LogLevel->Debug); }
sub info  { $_[0]->log($_[1], LogLevel->Info);  }
sub warn  { $_[0]->log($_[1], LogLevel->Warn);  }
sub error { $_[0]->log($_[1], LogLevel->Error); }

sub get_logs {
    my $self = shift;
    my @log_lines = ();
    for my $log (@{$self->{logs}}) {
        my $date_str = localtime($log->{date_s})->strftime('%Y-%m-%d %H:%M:%S') . sprintf(".%02d", $log->{date_m} / 10000);
        my $section_str = ($log->{section}) ? "[$log->{section}]" : "";
        my $llv_str = LogLevel->to_string_equal($log->{level});
        my @lines = split "\n", $log->{message};
        my $nth_line = 0;
        for my $line (@lines) {
            if ($line =~ /^\s*$/) { next; }
            push @log_lines, "$date_str  $llv_str $section_str $line\n";
            unless ($nth_line) {
                $date_str = Utils->align_with_words($date_str, "^");
                $llv_str = Utils->align_with_words($llv_str, "^");
                $section_str = Utils->align_with_words($section_str, "^");
                $nth_line = 1;
            }
        }
    }
    return join "", @log_lines;
}


package ResourceClass;

use constant {
    SecurityGroup => 0,
    Service       => 1,
    Rule          => 2,
};


package VraHandle;

use HTTP::Tiny;
use JSON;

sub new {
    my ($class, %args) = @_;
    my $self = {
        username => $args{username},
        password => $args{password},
        http => HTTP::Tiny->new,
        tenant_map => {},
        headers => {},

        url_refresh_token => $args{url_refresh_token},
        url_deployments => $args{url_deployments},
        url_project_id => $args{url_project_id},
        url_items => $args{url_items},
        url_login => $args{url_login},
    };

    bless $self, $class;
    return $self;
}

sub init {
    my $self = shift;

    # get refresh token
    my $body = encode_json {
        username => $self->username,
        password => $self->password,
    };
    my $http = HTTP::Tiny->new;
    my $resp = $self->{http}->get($self->{url_refresh_token});
}


package Main;

my $logger = Logger->new(section => "Setup");