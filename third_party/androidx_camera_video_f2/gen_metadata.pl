#!/usr/bin/perl
# Writes the Maven POM and Gradle module metadata of the patched camera-video artifact, derived
# from the upstream androidx.camera:camera-video:1.6.2 POM/.module (see README.md).
#
# Only these things change relative to upstream:
#   - coordinates: androidx.camera:camera-video:1.6.2 -> $GROUP:camera-video:$VERSION;
#   - .module: the "files" entry of both AAR variants (name, url, size, hashes of the patched AAR);
#   - .module: the sourcesElements and libraryVersionMetadata variants are dropped (their files
#     are not shipped here), and so is "createdBy" (it names the upstream Gradle build);
# every dependency and every atomic-group constraint is kept as published, so Gradle resolves
# exactly the same graph as with the upstream module.
#
# Usage: perl gen_metadata.pl <upstream .pom> <upstream .module> <patched .aar> <out dir>
#        perl gen_metadata.pl --roundtrip <upstream .module>   (formatter self-check)
use strict;
use warnings;
use JSON::PP;
use Digest::SHA;
use Digest::MD5;

my $GROUP = 'com.synapseauto.thirdparty.androidx.camera';
my $ARTIFACT = 'camera-video';
my $VERSION = '1.6.2-synapse-f2';

# Key order used by Gradle when it writes .module files; unknown keys (attribute names) sort
# alphabetically after these, as in the upstream file.
my @ORDER = qw(formatVersion component createdBy variants name group module version attributes
               dependencies dependencyConstraints files reason requires gradle buildId:
               url size sha512 sha256 sha1 md5);
my %RANK;
@RANK{@ORDER} = (0 .. $#ORDER);
sub by_gradle_order {
    my ($ka, $kb) = ($JSON::PP::a, $JSON::PP::b);
    my $ra = exists $RANK{$ka} ? $RANK{$ka} : 1000;
    my $rb = exists $RANK{$kb} ? $RANK{$kb} : 1000;
    return $ra <=> $rb || $ka cmp $kb;
}
my $json = JSON::PP->new->pretty->indent_length(2)->space_before(0)->sort_by(\&by_gradle_order);

sub slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or die "open $path: $!";
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

sub spew {
    my ($path, $data) = @_;
    open(my $fh, '>:raw', $path) or die "write $path: $!";
    print $fh $data;
    close $fh;
}

sub encode_module {
    my ($module) = @_;
    my $text = $json->encode($module);
    $text =~ s/\n\z//;    # upstream .module files have no trailing newline
    return $text;
}

if ($ARGV[0] eq '--roundtrip') {
    my $raw = slurp($ARGV[1]);
    my $again = encode_module(decode_json($raw));
    print $again eq $raw ? "roundtrip: identical\n" : "roundtrip: DIFFERENT\n";
    exit($again eq $raw ? 0 : 1);
}

my ($pom_in, $module_in, $aar, $out) = @ARGV;
die "usage: gen_metadata.pl <pom> <module> <aar> <out dir>\n" unless defined $out;
my $base = "$ARTIFACT-$VERSION";

# POM: coordinates only.
my $pom = slurp($pom_in);
my $old = "  <groupId>androidx.camera</groupId>\n  <artifactId>camera-video</artifactId>\n"
        . "  <version>1.6.2</version>\n";
my $count = () = $pom =~ /\Q$old\E/g;
die "pom: expected the upstream coordinates once, found $count\n" unless $count == 1;
$pom =~ s/\Q$old\E/  <groupId>$GROUP<\/groupId>\n  <artifactId>$ARTIFACT<\/artifactId>\n  <version>$VERSION<\/version>\n/;
spew("$out/$base.pom", $pom);

# .module
my $module = decode_json(slurp($module_in));
my $c = $module->{component};
die "module: unexpected component\n"
    unless $c->{group} eq 'androidx.camera' && $c->{module} eq 'camera-video' && $c->{version} eq '1.6.2';
@$c{qw(group module version)} = ($GROUP, $ARTIFACT, $VERSION);
delete $module->{createdBy};

my $bytes = slurp($aar);
my %file = (
    name => "$base.aar",
    url => "$base.aar",
    size => length($bytes) + 0,
    sha512 => Digest::SHA::sha512_hex($bytes),
    sha256 => Digest::SHA::sha256_hex($bytes),
    sha1 => Digest::SHA::sha1_hex($bytes),
    md5 => Digest::MD5::md5_hex($bytes),
);
my @kept;
for my $v (@{ $module->{variants} }) {
    next unless $v->{name} =~ /^releaseVariantRelease(Api|Runtime)Publication$/;
    my $files = $v->{files};
    die "module: variant $v->{name} does not list exactly the upstream AAR\n"
        unless @$files == 1 && $files->[0]{name} eq 'camera-video-1.6.2.aar';
    $v->{files} = [ {%file} ];
    push @kept, $v;
}
die "module: expected the api and runtime AAR variants\n" unless @kept == 2;
$module->{variants} = \@kept;
spew("$out/$base.module", encode_module($module));
print "wrote $out/$base.pom and $out/$base.module\n";
