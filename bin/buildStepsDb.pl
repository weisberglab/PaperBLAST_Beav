#!/usr/bin/perl -w
# Build the sqlite3 database of steps for GapMind
use strict;
use strict;
use DBI;
use Getopt::Long;
use FindBin qw{$RealBin};
use lib "$RealBin/../lib";
use Steps;
use pbutils qw{ReadTable ReadFastaEntry SqliteImport};

my $usage = <<END
Usage: buildStepsDb.pl -set set [ -dir tmp/set.aa ]

Assumes that the directory already contains curated.db and *.query for
each step as well as any related HMM models. Does not check for
consistency between *.query and curated.db.
END
;

my ($set, $workDir);
die $usage unless GetOptions('set=s' => \$set,
                             'dir=s' => \$workDir)
  && defined $set
  && @ARGV ==0;
$workDir = "$RealBin/../tmp/path.${set}" unless defined $workDir;
my $stepDir = "$RealBin/../gaps/$set";
foreach my $dir ($workDir, $stepDir) {
  die "No such directory: $dir\n" unless -d $dir;
}

my $curatedDb = "$workDir/curated.db";
my $dbhC = DBI->connect("dbi:SQLite:dbname=$curatedDb","","",{ RaiseError => 1 }) || die $DBI::errstr;

my @pathways = ReadTable("$stepDir/${set}.table", [ "pathwayId", "desc"]);
my @all = grep { $_->{pathwayId} eq "all" } @pathways;
die "Must have 1 pathwayId = all in ${set}.table" unless @all == 1;

print STDERR "Reading steps, query files, and other tables\n";
my %pathways = (); # pathwayId to step object
my %queries = (); # pathwayId to list of query rows
foreach my $pathway (@pathways) {
  my $pathwayId = $pathway->{pathwayId};
  next if $pathwayId eq "all";
  die "Duplicate pathwayId $pathwayId" if exists $pathways{$pathwayId};
  $pathways{$pathwayId} = ReadSteps("$stepDir/${pathwayId}.steps");
  my @queries = ReadTable("$workDir/${pathwayId}.query",
                          ["step","type","query","desc","file","sequence"]);
  die "No queries for $pathwayId" unless @queries > 0;
  $queries{$pathwayId} = \@queries;
}

my $reqs = ReadReqs("$stepDir/requires.tsv", \%pathways);

my $knownGapsFile = "$stepDir/${set}.known.gaps.tsv";
my @knownGapsIn = ();
@knownGapsIn = ReadTable($knownGapsFile,
                       ["genomeName","gdb","gid","pathway","step"])
  if -e $knownGapsFile;
my $curatedGapsFile = "$stepDir/${set}.curated.gaps.tsv";
my @curatedGaps = ();
@curatedGaps = ReadTable($curatedGapsFile,
                         ["genomeName","gdb","gid","pathway","step","class","comment"])
  if -e $curatedGapsFile;

# Read in marker sequences corresponding to known gaps
my %markerSeq = (); # gdb => gid => marker => sequence
# (Marker identifiers are gene names from TIGRFam like S20 or rpsA)
my $markerSeqFile = "$stepDir/${set}.known.gaps.markers.faa";
if (-e $markerSeqFile) {
  open(my $fh, "<", $markerSeqFile) || die "Cannot read $markerSeqFile\n";
  my $state = {};
  while (my ($header,$seq) = ReadFastaEntry($fh, $state)) {
    my ($orgId, $marker) = split /:/, $header;
    die $header unless $marker;
    my @parts = split /__/, $orgId;
    die $header unless @parts >= 2;
    my $gdb = shift @parts;
    my $gid = join("__", @parts);
    $markerSeq{$gdb}{$gid}{$marker} = $seq;
  }
}

my $stepsDb = "$workDir/steps.db";

my $tmpDir = $ENV{TMP} || "/tmp";
my $tmpDbFile = "$tmpDir/buildStepsDb.$$.db";
print STDERR "Building temporary database $tmpDbFile\n";

my $schema = "$RealBin/../lib/steps.sql";
unlink($tmpDbFile);
system("sqlite3 $tmpDbFile < $schema") == 0
  || die "Error loading schema $schema into $tmpDbFile -- $!";

# Build Pathway table
my @pathwayObj = map [ $_->{pathwayId}, $_->{desc} ], @pathways;
SqliteImport($tmpDbFile, "Pathway", \@pathwayObj);

# Build Rule, Step, and related tables
my @rules = ();
my @ruleInstances = ();
my @instanceComponents = ();
my @steps = ();
my @stepParts = ();
my $instanceId = 0;
my $componentId = 0;
my $partId = 0;
foreach my $pathwayId (sort keys %pathways) {
  my $stepsObj = $pathways{$pathwayId};
  my $stepHash = $stepsObj->{steps};
  my @stepList = sort { $a->{i} <=> $b->{i} } values(%$stepHash);
  my $ruleHash = $stepsObj->{rules};
  my $ruleOrder = $stepsObj->{ruleOrder};
  foreach my $ruleId (@$ruleOrder) {
    push @rules, [ $pathwayId, $ruleId ];
    my $instanceList = $ruleHash->{$ruleId};
    foreach my $instance (@$instanceList) {
      push @ruleInstances, [ $pathwayId, $ruleId, $instanceId ];
      foreach my $component (@$instance) {
        my $subRuleId = "";
        my $stepId = "";
        if (exists $ruleHash->{$component}) {
          $subRuleId = $component;
        } elsif (exists $stepHash->{$component}) {
          $stepId = $component;
        } else {
          die "Unknown component $component in $ruleId for $pathwayId";
        }
        push @instanceComponents, [ $pathwayId, $ruleId, $instanceId, $componentId, $subRuleId, $stepId ];
        $componentId++;
      }
      $instanceId++;
    } # end loop over rule instances
  } # end loop over rules

  foreach my $stepObj (@stepList) {
    my $stepId = $stepObj->{name};
    push @steps, [ $pathwayId, $stepId, $stepObj->{desc} ];
    foreach my $part (@{ $stepObj->{search} }) {
      my ($type, $value) = @$part;
      push @stepParts, [ $pathwayId, $stepId, $partId, $type, $value ];
      $partId++;
    }
  }
}
SqliteImport($tmpDbFile, "Rule", \@rules);
SqliteImport($tmpDbFile, "RuleInstance", \@ruleInstances);
SqliteImport($tmpDbFile, "InstanceComponent", \@instanceComponents);
SqliteImport($tmpDbFile, "Step", \@steps);
SqliteImport($tmpDbFile, "StepPart", \@stepParts);

# Build StepQuery table
my @queries = ();
my $queryId = 0;
my %hmmFileName = (); # hmm id => hmm file (name only, no path information)
foreach my $pathwayId (sort keys %queries) {
  foreach my $row (@{ $queries{$pathwayId} }) {
    my $stepId = $row->{step};
    my $queryType = $row->{type};
    my $desc = $row->{desc};
    my $seq = $row->{sequence};
    my ($curatedIds, $uniprotId, $protId, $hmmId, $hmmFileName);
    if ($queryType eq "curated" || $queryType eq "ignore") {
      $curatedIds = $row->{query};
    } elsif ($queryType eq "curated2") {
      $protId = $row->{query};
    } elsif ($queryType eq "uniprot") {
      $uniprotId = $row->{query};
    } elsif ($queryType eq "hmm") {
      $hmmId = $row->{query};
      die "Empty file for hmm $hmmId for pathway $pathwayId step $stepId"
        unless $row->{file};
      $hmmFileName = $row->{file};
      $hmmFileName{$hmmId} = $row->{file};
    } else {
      die "Unknown query type $queryType for pathway $pathwayId step $stepId";
    }
    push @queries, [ $pathwayId, $stepId, $queryId, $queryType,
                     $curatedIds, $uniprotId, $protId, $hmmId, $hmmFileName, $desc, $seq ];
    $queryId++;
  }
}
SqliteImport($tmpDbFile, "StepQuery", \@queries);

# Build Requirement table
my @requirements = ();
foreach my $row (@$reqs) {
  my $reqRule = exists $row->{requiredRule} ? $row->{requiredRule} : "";
  my $reqStep = exists $row->{requiredStep} ? $row->{requiredStep} : "";
  push @requirements, [ $row->{pathway}, $row->{rule},
                        $row->{requiredPath}, $reqRule, $reqStep,
                        $row->{not},
                        $row->{comment} ]; # what about reqSpec?
}
SqliteImport($tmpDbFile, "Requirement", \@requirements);

# Build KnownGap table
# gdb::gid::pathway::step => row
my %curatedGaps = map { join("::", $_->{gdb}, $_->{gid}, $_->{pathway}, $_->{step}) => $_ } @curatedGaps;

my @knownGaps = ();
my %hasKnownGap = (); # gdb => gid => 1
foreach my $kg (@knownGapsIn) {
  print STDERR "No marker sequences for $kg->{gdb} $kg->{gid}, which has known gaps\n"
    unless exists $markerSeq{ $kg->{gdb} }{ $kg->{gid} };
  $hasKnownGap{ $kg->{gdb} }{ $kg->{gid} } = 1;
  my $key = join("::", $kg->{gdb}, $kg->{gid}, $kg->{pathway}, $kg->{step});
  my ($gapClass, $comment);
  if (exists $curatedGaps{$key}) {
    $gapClass = $curatedGaps{$key}{class};
    $comment = $curatedGaps{$key}{comment};
  }
  push @knownGaps, [ $kg->{gdb}, $kg->{gid}, $kg->{genomeName},
                     $kg->{pathway}, $kg->{step},
                     $gapClass, $comment ];
}
SqliteImport($tmpDbFile, "KnownGap", \@knownGaps);

# Build KnownGapMarker table
my @markerSeq = ();
foreach my $gdb (sort keys %markerSeq) {
  my $gidHash = $markerSeq{$gdb};
  foreach my $gid (sort keys %$gidHash) {
    if (!exists $hasKnownGap{$gdb}{$gid}) {
      print STDERR "Warning: $markerSeqFile includes $gdb $gid which has no known gaps\n";
      next;
    }
    my $markerHash = $gidHash->{$gid};
    foreach my $marker (sort keys %$markerHash) {
      my $seq = $markerHash->{$marker};
      push @markerSeq, [ $gdb, $gid, $marker, $seq ];
    }
  }
}
SqliteImport($tmpDbFile, "KnownGapMarker", \@markerSeq);

# Build the HMM table
my $dbhS = DBI->connect("dbi:SQLite:dbname=$tmpDbFile","","",{ RaiseError => 1 }) || die $DBI::errstr;
my $hmmInsertStatement = $dbhS->prepare(qq{ INSERT INTO HMM VALUES(?,?) });
foreach my $hmmId (sort keys %hmmFileName) {
  my $hmmFile = "$workDir/" . $hmmFileName{$hmmId};
  die "Model for $hmmId should be in $hmmFile\n"
    unless -e $hmmFile;
  open(my $fhH, "<", $hmmFile) || die "Cannot read $hmmFile";
  my @lines = <$fhH>;
  close($fhH) || die "Error reading $hmmFile";
  die "$hmmFile for $hmmId is empty" unless @lines > 0;
  $hmmInsertStatement->execute($hmmId, join("", @lines))
    || die "Failed ot insert into HMM";
}
$dbhS->disconnect();

system("cp $tmpDbFile $stepsDb") == 0 || die "Copying $tmpDbFile to $stepsDb failed: $!";
unlink($tmpDbFile);
print STDERR "Built steps database $stepsDb\n";