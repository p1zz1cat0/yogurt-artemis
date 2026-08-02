#!/usr/bin/perl
use strict;
use warnings;

my ($source, $destination) = @ARGV;
die "usage: patch_static_io_symbols.pl source.a destination.a\n"
    unless defined $source && defined $destination;

open my $input, '<:raw', $source or die "open $source: $!\n";
local $/;
my $archive = <$input>;
close $input;

my %replacements = (
    "_fopen\0"  => "_yopen\0",
    "_fclose\0" => "_yclose\0",
    "_fread\0"  => "_yread\0",
    "_fseek\0"  => "_yseek\0",
    "_ftell\0"  => "_ytell\0",
    "_exit\0"   => "_yxit\0",
    "_abort\0"  => "_ybort\0",
    "_glShaderSource\0" => "_ygShaderSource\0",
    "_NSSearchPathForDirectoriesInDomains\0"
        => "_YoghourtPathForDirectoriesInDomains\0",
    "UIFont\0" => "YGFont\0",
);

for my $source_symbol (sort keys %replacements) {
    my $count = ($archive =~ s/\Q$source_symbol\E/$replacements{$source_symbol}/g);
    die "symbol $source_symbol was not present in $source\n" unless $count;
}

open my $output, '>:raw', $destination or die "open $destination: $!\n";
print {$output} $archive;
close $output;
