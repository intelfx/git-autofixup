#!/usr/bin/perl
package Util;

use strict;
use warnings FATAL => 'all';

use Carp qw(croak);
use Cwd;
use English qw(-no_match_vars);
use File::Temp qw(tempdir);
use Test::More;

require './t/repo.pl';
require './git-autofixup';

sub check_test_deps {
    if ($OSNAME eq 'MSWin32') {
        plan skip_all => 'Run from Cygwin or Git Bash on Windows'
    } elsif (!has_git()) {
        plan skip_all => 'git version 1.7.4+ required'
    }
}

sub has_git {
    my $stdout = qx{git --version};
    return if $? != 0;
    my ($x, $y, $z) = $stdout =~ /(\d+)\.(\d+)(?:\.(\d+))?/;
    defined $x or die "unexpected output from git: $stdout";
    $z = defined $z ? $z : 0;
    my $cmp = $x <=> 1 || $y <=> 7 || $z <=> 4;
    return $cmp >= 0;
}

sub test_autofixup_strict {
    my $params = shift;
    my $strict_levels = $params->{strict} or croak "strictness levels not given";
    delete $params->{strict};
    my $autofixup_opts = $params->{autofixup_opts} || [];
    if (grep /^(--strict|-s)/, @{$autofixup_opts}) {
        croak "strict option already given";
    }
    my $name = $params->{name} || croak "name not given";
    for my $strict (@{$strict_levels}) {
        $params->{name} = "$name, strict=$strict";
        $params->{autofixup_opts} = ['-s' => $strict, @{$autofixup_opts}];
        test_autofixup($params);
    }
}

# test_autofixup initializes a git repo in a tempdir, creates given "upstream"
# and "topic" commits, applies changes to the working directory, runs
# autofixup, and compares wanted `git log` and `git diff` outputs to actual
# ones.
#
# Arguments must be given in a hashref:
# name: test name or description
# upstream_commits: sub or hash refs that must not be fixed up
# topic_commits: sub or hash refs representing commits that can be fixed up
# unstaged: sub or hash ref of working directory changes
# staged: sub or hash ref of index changes
# log_want: expected log output for new fixup commited
# staged_want: expected log output for the staging area
# unstaged_want: expected diff output for the working tree
# autofixup_opts: command-line options to pass thru to autofixup
#
# The upstream_commits and topic_commits arguments are heterogeneous lists of
# sub and hash refs. Hash refs are interpreted as being maps of filenames to
# contents to be written. If more flexibility is needed a subref can be given
# to manipulate the working directory.
sub test_autofixup {
    my ($args) = shift;
    my $name = defined($args->{name}) ? $args->{name}
             : croak "no test name given";
    my $upstream_commits = $args->{upstream_commits} || [];
    my $topic_commits = $args->{topic_commits} || [];
    my $unstaged = defined($args->{unstaged}) ? $args->{unstaged}
                 : croak "no unstaged changes given";
    my $staged = $args->{staged};
    my $log_want = defined($args->{log_want}) ? $args->{log_want}
                 : croak "wanted log output not given";
    my $staged_want = $args->{staged_want};
    my $unstaged_want = $args->{unstaged_want};
    my $exit_code_want = $args->{exit_code};
    my $autofixup_opts = $args->{autofixup_opts} || [];
    push @{$autofixup_opts}, '--exit-code';
    if (!$upstream_commits && !$topic_commits) {
        croak "no upstream or topic commits given";
    }
    if (exists $args->{strict}) {
        croak "strict key given; use test_autofixup_strict instead";
    }

    eval {
        my $repo = Repo->new();

        $repo->create_commits(@$upstream_commits);
        my $upstream_rev = $repo->current_commit_sha();

        $repo->create_commits(@$topic_commits);
        my $pre_fixup_rev = $repo->current_commit_sha();

        if (defined($staged)) {
            $repo->write_change($staged);
            # We're at the repo root, so using -A will change everything even
            # in pre-v2 versions of git. See git commit 808d3d717e8.
            run(qw(git add -A));
        }

        $repo->write_change($unstaged);

        run('git', '--no-pager',  'log', "--format='%h %s'", "${upstream_rev}..");
        my $exit_code_got = $repo->autofixup(@{$autofixup_opts}, $upstream_rev);

        my $ok = exit_code_ok(want => $exit_code_want, got => $exit_code_got);
        my $wants = {
            fixup_log => $log_want,
            staged => $staged_want,
            unstaged => $unstaged_want,
        };
        $ok &&= repo_state_ok($repo, $pre_fixup_rev, $wants);
        ok($ok, $name);
    };
    if ($@) {
        diag($@);
        fail($name);
    }
    return;
}

# Take wanted and actual autofixup exit codes as a hash with keys ('want',
# 'got') and return true if want and got are equal or if want is undefined.
#
# eg: exit_code_got(want => 3, got => 2)
#
# Params are taken as a hash since the order matters and it seems difficult to
# get the order right if the args aren't named.
sub exit_code_ok {
    my %args = @_;
    defined $args{got} or croak "got exit code is undefined";
    if (defined $args{want} && $args{want} != $args{got}) {
        diag("exit_code_want=$args{want},exit_code_got=$args{got}");
        return 0;
    }
    return 1;
}

# Take wanted and actual listrefs of upstream SHAs as a hash with keys ('want',
# 'got') and return true if want and got are equal.
#
# eg: exit_code_got(want => 3, got => 2)
sub upstreams_ok {
    my %args = @_;
    defined $args{want} or croak 'wanted upstream list must be given';
    defined $args{got} or croak 'actual upstream list must be given';
    my @wants = @{$args{want}};
    my @gots = @{$args{got}};
    my $max_len = @wants > @gots ? @wants : @gots;
    my $ok = 1;
    for my $i (0..$max_len - 1) {
        my $want = defined $wants[$i] ? $wants[$i] : '';
        my $got = defined $gots[$i] ? $gots[$i] : '';
        if (!$want || !$got || $want ne $got) {
            diag("upstream mismatch,i=$i,want=$want,got=$got");
            $ok = 0;
        }
    }
    return $ok;
}

sub repo_state_ok {
    my ($repo, $pre_fixup_rev, $wants) = @_;
    my $ok = 1;

    for my $key (qw(fixup_log staged unstaged)) {
        next if (!defined $wants->{$key});

        my $want = $wants->{$key};

        my $got;
        if ($key eq 'fixup_log') {
            $got = $repo->log_since($pre_fixup_rev);
        } elsif ($key eq 'staged') {
            $got = $repo->diff('--cached');
        } elsif ($key eq 'unstaged') {
            $got = $repo->diff('HEAD');
        }

        if ($got ne $want) {
            diag("${key}_got=<<EOF\n${got}EOF\n${key}_want=<<EOF\n${want}EOF\n");
            $ok = 0;
        }
    }

    if (!defined($wants->{staged})) {
        my $got = $repo->diff('--cached');
        if ($got) {
            diag("staged_got=<<EOF\n${got}EOF\nno staged changes expected\n");
            $ok = 0;
        }
    }

    return $ok;
}

sub run {
    print '# ', join(' ', @_), "\n";
    system(@_) == 0 or croak "$!";
}

sub write_file {
    my ($filename, $contents) = @_;
    open(my $fh, '>', $filename) or croak "$!";
    print {$fh} $contents or croak "$!";
    close $fh or croak "$!";
}

1;
