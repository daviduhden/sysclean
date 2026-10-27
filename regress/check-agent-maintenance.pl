#!/usr/bin/perl
#
# Check agent/skill instruction structure and require instruction maintenance
# alongside repository changes. Semantic relevance still requires review.
#

use v5.36;
use strict;
use warnings;

use Cwd qw(abs_path);
use File::Basename qw(dirname basename);
use File::Spec;

sub fail(@messages) {
    print STDERR "agent-maintenance: ", join( '', @messages ), "\n";
    exit 1;
}

sub git_output(@args) {
    open( my $git, '-|', 'git', @args )
      or fail("cannot run git: $!\n");
    local $/;
    my $output = <$git> // '';
    close($git) or fail("git @args failed (status $? )\n");
    return $output;
}

sub read_text($path) {
    open( my $fh, '<', $path ) or fail("cannot read $path: $!\n");
    local $/;
    return <$fh> // '';
}

sub instruction_kind($path) {
    return 'root-agent' if $path eq 'AGENTS.md';
    return 'agent' if basename($path) eq 'AGENTS.md'
      || $path =~ m{\.agent\.md\z}i
      || basename($path) eq 'CLAUDE.md'
      || $path eq '.cursorrules'
      || $path eq '.github/copilot-instructions.md'
      || $path =~ m{\A\.github/instructions/.+\.instructions\.md\z}
      || $path =~ m{\A\.cursor/rules/.+\.mdc\z}
      || $path =~ m{\A\.claude/rules/.+\.md\z};
    return 'skill' if basename($path) eq 'SKILL.md';
    return;
}

sub markdown_links($path, $content, $errors) {
    while ( $content =~ m{\[[^\]]*\]\(\s*<?([^)>\s]+)>?(?:\s+[^)]*)?\)}g ) {
        my $target = $1;
        next if $target =~ m{\A(?:[A-Za-z][A-Za-z0-9+.-]*:|//)};
        $target =~ s/[?#].*\z//;
        next if $target eq '';
        my @candidates =
          $target =~ m{\A/}
          ? ( File::Spec->catfile( '.', substr( $target, 1 ) ) )
          : ( File::Spec->catfile( dirname($path), $target ), $target );
        next if grep { -e $_ } @candidates;
        push @$errors, "$path: local Markdown target does not exist: $target";
    }

    while ( $content =~ /`([^`]+)`/g ) {
        my $target = $1;
        next
          if $target =~ m{\A/}
          || $target =~ /[\s=<>*]/
          || $target =~ m{[/\\]\z}
          || $target =~ /\A(?:CLAUDE\.md|SKILL\.md|\.agent\.md)\z/;
        next
          if $target !~ /\.(?:md|pl|pm|t|8|ignore)\z/
          && $target !~ /\A(?:Makefile|LICENSE)\z/;
        my @candidates = ( File::Spec->catfile( dirname($path), $target ), $target );
        next if grep { -e $_ } @candidates;
        push @$errors, "$path: local repository path does not exist: $target";
    }
}

sub validate_instruction($path, $root, $errors) {
    my $kind = instruction_kind($path);
    return if !defined($kind);
    my $fullpath = File::Spec->catfile( $root, $path );
    return if !-f $fullpath;    # A deleted file is validated through its replacement.
    my $content = read_text($fullpath);

    my ( $fence_char, $fence_length );
    for my $line ( split( /\n/, $content ) ) {
        if ( !defined($fence_char) ) {
            if ( $line =~ /^ {0,3}(`{3,}|~{3,})/ ) {
                $fence_char   = substr( $1, 0, 1 );
                $fence_length = length($1);
            }
        }
        elsif ( $line =~ /^ {0,3}(\Q$fence_char\E{$fence_length,})\s*\z/ ) {
            undef $fence_char;
            undef $fence_length;
        }
    }
    push @$errors, "$path: unmatched Markdown code fence"
      if defined($fence_char);

    if ( $kind eq 'root-agent' ) {
        push @$errors, "$path: missing Continuous Agent & Skills Maintenance section"
          if $content !~ /^## Continuous Agent & Skills Maintenance\s*$/m;
        push @$errors, "$path: missing mandatory completion checklist"
          if $content !~ /^### Mandatory Definition of Done\s*$/m;
    }
    elsif ( $kind eq 'skill' ) {
        if ( $content !~
            /\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)/s )
        {
            push @$errors, "$path: missing Agent Skills YAML frontmatter";
        }
        else {
            my $frontmatter = $1;
            push @$errors, "$path: frontmatter is missing name"
              if $frontmatter !~ /^name:\s*[A-Za-z0-9_-]+\s*$/m;
            push @$errors, "$path: frontmatter is missing description"
              if $frontmatter !~ /^description:\s*\S/m;
        }
        push @$errors, "$path: missing Maintenance & Continuous Learning section"
          if $content !~ /^## Maintenance & Continuous Learning\s*$/m;
    }
    elsif ( $content !~ /^## Post-Change Knowledge Synchronization\s*$/m ) {
        push @$errors, "$path: missing Post-Change Knowledge Synchronization section";
    }

    markdown_links( $path, $content, $errors );
}

sub changed_paths($base) {
    my $output = git_output( 'diff', '--name-only', '-z', $base, '--' );
    my @paths = grep { length } split( /\0/, $output );
    my $untracked = git_output( 'ls-files', '--others', '--exclude-standard', '-z' );
    push @paths, grep { length } split( /\0/, $untracked );
    my %seen;
    return grep { !$seen{$_}++ } @paths;
}

sub meaningful_instruction_diff( $base, $path ) {
    my $diff = git_output( 'diff', '--no-ext-diff', '--unified=0', $base, '--', $path );
    if ( !length($diff) && -f $path ) {
        $diff = join( '', map { "+$_\n" } split( /(?<=\n)/, read_text($path) ) );
    }
    my ( $changed_chars, $content_lines ) = ( 0, 0 );
    while ( $diff =~ /^([+-])(?!\1\1)(.*)$/gm ) {
        my $line = $2;
        next if $line =~ /^\s*$/;
        $changed_chars += length($line);
        $content_lines++
          if $line !~ /^\s*(?:#{1,6}\s|name:\s|description:\s|---\s*$)/;
    }
    return $changed_chars >= 24 && $content_lines > 0;
}

my $mode = shift @ARGV // '';
my $base;
if ( $mode eq '--base' ) {
    $base = shift @ARGV;
    fail("--base requires a Git revision\n") if !defined($base) || $base eq '';
}
elsif ( $mode ne '--lint' ) {
    fail("usage: $0 --lint | --base <git-revision>\n");
}
fail("unexpected arguments\n") if @ARGV;

my $root = abs_path( git_output( 'rev-parse', '--show-toplevel' ) );
chomp $root;
chdir($root) or fail("cannot enter repository root $root: $!\n");

my @tracked = grep { length } split( /\0/, git_output( 'ls-files', '-z' ) );
my @untracked = grep { length }
  split( /\0/, git_output( 'ls-files', '--others', '--exclude-standard', '-z' ) );
my %known = map { $_ => 1 } ( @tracked, @untracked );
my @instructions = sort grep { defined instruction_kind($_) } keys %known;
my @errors;

push @errors, 'AGENTS.md: required root agent instructions are missing'
  if !$known{'AGENTS.md'} || !-f 'AGENTS.md';
validate_instruction( $_, $root, \@errors ) for @instructions;

if ( $mode eq '--base' ) {
    my @changed = changed_paths($base);
    my @changed_instruction = grep { defined instruction_kind($_) } @changed;
    my @updated_instruction = grep { -f $_ } @changed_instruction;
    my @changed_project = grep { !defined instruction_kind($_) } @changed;

    if (@changed_project && !@updated_instruction) {
        push @errors,
          'repository files changed without an AGENTS.md, agent, or SKILL.md update';
    }
    if (@updated_instruction) {
        my $meaningful = grep { meaningful_instruction_diff( $base, $_ ) }
          @updated_instruction;
        push @errors,
          'instruction changes are empty or whitespace-only; add verified, reusable maintenance knowledge'
          if !$meaningful;
    }
    elsif (@changed_instruction) {
        push @errors, 'instruction files were deleted without an updated replacement';
    }
    print "agent-maintenance: ", scalar(@changed),
      " changed/untracked path(s), ", scalar(@changed_instruction),
      " changed instruction path(s)\n";
}

if (@errors) {
    print STDERR "agent-maintenance: FAIL\n";
    print STDERR " - $_\n" for @errors;
    exit 1;
}

print "agent-maintenance: PASS (structure and local references validated)\n";
exit 0;
