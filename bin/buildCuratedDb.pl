#!/usr/bin/perl -w
# Build the sqlite3 database of curated proteins for GapMind and Curated Clusters
use strict;
use DBI;
use Getopt::Long;
use FindBin qw{$RealBin};
use lib "$RealBin/../lib";
use pbutils qw{ReadFastaEntry ReadTable SqliteImport};
sub DoSqliteCmd($$);

my $staticDir = "$RealBin/../static";
my $usage = <<END
buildCurateDb.pl -dir tmp/path.aa

Assumes that the directory already contains curated.faa,
curated.faa.info, curated2.faa, and hetero.tab. If you don't want to
inlude pfam hits (used by curatedClusters.cgi, but not by GapMind
itself), set pfam.hits.tab to be empty.

Also uses metacyc.reaction_compounds and metacyc.reaction_links from
static/

Optional arguments:
-curated dir/curated.faa
-curated2 dir/curated2.faa
-hetero dir/hetero.tab
-pfamhits dir/pfam.hits.tab
-static $staticDir
-out dir/curated.db
END
;

my ($dir, $curatedFile, $curated2File, $heteroFile, $pfamHitsFile, $dbFile);
die $usage
  unless GetOptions('dir=s' => \$dir,
                    'curated=s' => \$curatedFile,
                    'curated2=s' => \$curated2File,
                    'hetero=s' => \$heteroFile,
                    'pfamhits=s' => \$pfamHitsFile,
                    'static=s' => \$staticDir,
                    'out=s' => \$dbFile)
  && @ARGV == 0
  && defined $dir;

die "No such directory: $dir\n" unless -d $dir;
die "No such directory: $staticDir\n" unless -d $staticDir;

$curatedFile = "$dir/curated.faa" unless defined $curatedFile;
my $curatedInfoFile = "$curatedFile.info";
$curated2File = "$dir/curated2.faa" unless defined $curated2File;
$heteroFile = "$dir/hetero.tab" unless defined $heteroFile;
$pfamHitsFile = "$dir/pfam.hits.tab" unless defined $pfamHitsFile;
$dbFile = "$dir/curated.db" unless defined $dbFile;
my $reactionLinksFile = "$staticDir/metacyc.reaction_links";
my $reactionCompoundsFile = "$staticDir/metacyc.reaction_compounds";

foreach my $file ($curatedFile, $curatedInfoFile, $curated2File, $heteroFile, $pfamHitsFile,
                  $reactionLinksFile, $reactionCompoundsFile) {
  die "No such file: $file\n" unless -e $file;
}

my $tmpDir = $ENV{TMP} || "/tmp";
my $tmpDbFile = "$tmpDir/buildCuratedDb.$$.db";
print STDERR "Building temporary database $tmpDbFile\n";

my $schema = "$RealBin/../lib/curated.sql";
system("sqlite3 $tmpDbFile < $schema") == 0
  || die "Error loading schema $schema into $tmpDbFile -- $!";

# the orgs and id2s fields are optional
my @info = ReadTable($curatedInfoFile, ["ids", "length", "descs"]);
my @curatedInfo = map { $_->{descs} =~ s/\r */ /g;
                        [ $_->{ids}, $_->{length}, $_->{descs},
                          $_->{id2s} || "", $_->{orgs} || "" ]
                      } @info;
SqliteImport($tmpDbFile, "CuratedInfo", \@curatedInfo);
print STDERR "Loaded CuratedInfo\n";

my @curatedSeq = ();
open(my $fhFaa, "<", $curatedFile) || die "Cannot read $curatedFile\n";
my $state = {};
while (my ($curatedIds, $seq) = ReadFastaEntry($fhFaa, $state)) {
  push @curatedSeq, [ $curatedIds, $seq ];
}
close($fhFaa) || die "Error reading $curatedFile";
SqliteImport($tmpDbFile, "CuratedSeq", \@curatedSeq);
print STDERR "Loaded CuratedSeq\n";

my @curated2 = ();
open($fhFaa, "<", "$curated2File") || die "Cannot read $curated2File\n";
$state = {};
while (my ($header, $seq) = ReadFastaEntry($fhFaa, $state)) {
  my @F = split / /, $header;
  my $protId = shift @F;
  my $desc = join(" ", @F);
  push @curated2, [ $protId, $desc, $seq ];
}
close($fhFaa) || die "Error reading $curated2File";
SqliteImport($tmpDbFile, "Curated2", \@curated2);

my @heteroIn = ReadTable($heteroFile, ["db","protId","comment"]);
my @hetero = map [ $_->{db} . "::" . $_->{protId}, $_->{comment} ], @heteroIn;
SqliteImport($tmpDbFile, "Hetero", \@hetero);
print STDERR "Loaded Hetero\n";

my @pfamHits = ();
open (my $fhHits, "<", $pfamHitsFile) || die "Cannot read $pfamHitsFile\n";
while (my $line = <$fhHits>) {
  chomp $line;
  my ($protId, $hmmName, $hmmAcc, $eval, $bits,
      $protBeg, $protEnd, $protLen,
      $hmmBeg, $hmmEnd, $hmmLen) = split /\t/, $line;
  die unless defined $hmmLen && $hmmLen =~ m/^\d+$/;
  push @pfamHits, [ $protId, $hmmName, $hmmAcc, $eval, $bits,
                    $protBeg, $protEnd, $protLen,
                    $hmmBeg, $hmmEnd, $hmmLen ];
}
SqliteImport($tmpDbFile, "CuratedPFam", \@pfamHits);
print STDERR "Loaded CuratedPFam\n";

my @compoundInReaction = ();
my %crKey = (); # rxnId::cmpId::side must be unique
open (my $fhCompounds, "<", $reactionCompoundsFile)
  || die "Cannot read $reactionCompoundsFile";
while (my $line = <$fhCompounds>) {
  chomp $line;
  my @F = split /\t/, $line;
  my $rxnId = shift @F;
  my $rxnLocation = shift @F;
  foreach my $spec (@F) {
    my ($side, $coeff, $compartment, $cmpId, $cmpDesc) = split /:/, $spec;
    die unless defined $cmpDesc;
    my $key = join("::", $rxnId, $cmpId, $side);
    push @compoundInReaction, [ $rxnId, $rxnLocation, $cmpId, $cmpDesc,
                                $side, $coeff, $compartment ]
      unless exists $crKey{$key};
    $crKey{$key} = 1;
  }
}
close($fhCompounds) || die "Error reading $reactionCompoundsFile";
SqliteImport($tmpDbFile, "CompoundInReaction", \@compoundInReaction);

my %idToIds = ();
foreach my $info (@info) {
  my $curatedIds = $info->{ids};
  foreach my $id (split /,/, $curatedIds) {
    $idToIds{$id} = $curatedIds;
  }
}

my @enzymeForReaction = ();
my %erKey = (); # curatedIds ::: $rxnId should be unique
open(my $fhRxnLinks, "<", $reactionLinksFile)
  || die "Error reading $reactionLinksFile";
my $nEnzSkip = 0;
while (my $line = <$fhRxnLinks>) {
  chomp $line;
  my @F = split /\t/, $line;
  my $rxnId = shift @F;
  my $enzDesc = shift @F;
  foreach my $id (@F) {
    if (!exists $idToIds{$id}) {
      $nEnzSkip++;
    } else {
      my $curatedIds = $idToIds{$id};
      my $key = join(":::", $curatedIds, $rxnId);
      push @enzymeForReaction, [ $curatedIds, $rxnId, $enzDesc ]
        unless exists $erKey{$key};
      $erKey{$key} = 1;
    }
  }
}
close($fhRxnLinks) || die "Error reading $reactionLinksFile";
print STDERR "Warning: skipped $nEnzSkip entries from $reactionLinksFile with unknown protein ids\n"
  if $nEnzSkip > 0;
SqliteImport($tmpDbFile, "EnzymeForReaction", \@enzymeForReaction);

system("cp $tmpDbFile $dbFile") == 0 || die "Copying $tmpDbFile to $dbFile failed: $!";
unlink($tmpDbFile);
print STDERR "Built curated database $dbFile\n";


