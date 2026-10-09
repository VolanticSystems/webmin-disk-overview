#!/usr/bin/perl
# test-disk-page-render.pl - runs disk-focus/index.cgi (the page the disk dial
# opens) with the theme header/footer stubbed out, once per tab, and checks
# what it prints. Authentic cannot load from a command line, so how the page
# LOOKS in a browser is not covered; everything the page computes is.
# Read-only.

BEGIN {
	push(@INC, "/usr/libexec/webmin");
	$ENV{'LIBROOT'} ||= "/usr/libexec/webmin";
	$ENV{'REMOTE_USER'} ||= 'root';
	$ENV{'BASE_REMOTE_USER'} ||= 'root';
	$ENV{'WEBMIN_CONFIG'} ||= '/etc/webmin';
	$ENV{'WEBMIN_VAR'} ||= '/var/webmin';
	$ENV{'REQUEST_METHOD'} = 'GET';
	# Webmin works out the module from the script path; run as the page.
	$0 = "/usr/libexec/webmin/disk-focus/index.cgi";
	$ENV{'SCRIPT_FILENAME'} = $0;
}
my $fails = 0;
sub check { my ($ok, $l, $d) = @_; printf("%s  %-52s %s\n", $ok ? 'PASS' : 'FAIL', $l, $d || ''); $fails++ if (!$ok); }

# DF_DIR runs the page from another copy of the module (a mutation control).
chdir($ENV{'DF_DIR'} || "/usr/libexec/webmin/disk-focus") || die "chdir: $!";
# DF_PAGE runs another copy of the page (e.g. a backup) as a control.
open(my $fh, "<", $ENV{'DF_PAGE'} || "index.cgi") || die "open: $!";
my $code = do { local $/; <$fh> };
close($fh);
$code =~ s/&ui_print_header\([^;]*\);/print "<html><body>";/s;
$code =~ s/&ui_print_footer\([^;]*\);/print "<\/body><\/html>";/gs;
$code =~ s/^#!.*\n//;
# The theme's button needs a live session too (get_button_style); plain stand-in.
$code =~ s/&ui_submit\(/&test_submit(/g;
sub test_submit { return "<input type=submit value=\"$_[0]\">"; }

my $out = '';
{
	local *STDOUT;
	open(STDOUT, ">", \$out) || die "capture: $!";
	eval $code;
	close(STDOUT);
}
check(!$@, "page runs without dying", $@ ? substr($@, 0, 90) : '');
check(length($out) > 2000, "produced a real page", length($out)." bytes");

foreach my $w (
	[ "Storage",                         "Storage tab present" ],
	[ "Who's using it",                  "Who's using it tab present" ],
	[ "nvme0n1 + nvme1n1",               "NVMe pair shown as one storage group" ],
	[ "<tt>/data</tt>",                  "/data listed under the Seagate" ],
	[ "RAID0 (striped, no redundancy)",  "/ labelled RAID0 striped" ],
	[ "RAID1 (mirrored)",                "/boot labelled RAID1 mirrored" ],
	[ "Biggest users on <tt>/</tt>",     "per-user list for / present" ],
	[ "quota/list_users.cgi?dir=%2F",    "link to the full Disk Quotas list for /" ],
	[ "Biggest Virtualmin domains",      "per-domain list present" ],
    ) {
	check(index($out, $w->[0]) >= 0, $w->[1]);
	}
check(index($out, "Dial settings") < 0, "no Dial settings tab any more");
check($out =~ m{<a [^>]*href='/sysinfo\.cgi\?mod=virtual-server'[^>]*>&larr; Back to dashboard</a>} ? 1 : 0,
      "Back to dashboard button at the top");
# Each group's badge must match the live setting, and be a link to
# Virtualmin's Status collection category that returns here after Save.
my %vc;
&read_file("/etc/webmin/virtual-server/config", \%vc);
my $want = collect_fs::wanted_dirs($vc{'collect_fs'} || '');
my $href = qr{<a [^>]*href=['"]\.\./config\.cgi\?module=virtual-server&amp;section=line7&amp;_cscript=\.\.%2Fdisk-focus%2F['"][^>]*>};
my ($on, $off) = (1, 1);
foreach my $g ([ 'nvme0n1 + nvme1n1', '/' ], [ 'sda', '/data' ]) {
	my $exp = !$want || $want->{$g->[1]} ? 'Counted on the dashboard dial'
					     : 'Not counted on the dial';
	my $ok = $out =~ /<h3>\Q$g->[0]\E[^<]*${href}\Q$exp\E<\/a>/ ? 1 : 0;
	check($ok, "$g->[0]: badge '$exp' links to the setting");
	$on &&= $ok;
	}
if (!$on || !$off) {
	my $i = index($out, 'Counted on the dashboard dial');
	print "      context: ", ($i < 0 ? "no badge in page"
			       : substr($out, $i > 200 ? $i - 200 : 0, 300)), "\n";
	}
# Numbers must follow the dashboard dial's rule: used = total - free, so the
# root-reserved blocks count as used and used + free = total. (Until
# 2026-10-09 the page counted the reserve as free and read ~5 points emptier
# than the dial: 37% vs 42% on fsn1.)
&foreign_require("mount");
my (undef, undef, $allfs) = &mount::local_disk_space();
my %fsd = map { $_->{'dir'}, $_ } @$allfs;
foreach my $g ([ 'nvme0n1 + nvme1n1', '/', '/boot' ], [ 'sda', '/data' ]) {
	my ($n, @dirs) = @$g;
	my ($t, $f) = (0, 0);
	foreach my $d (@dirs) { $t += $fsd{$d}->{'total'}; $f += $fsd{$d}->{'free'}; }
	my $line = &nice_size($t - $f)." of ".&nice_size($t)." used, ".&nice_size($f)." free";
	check(index($out, "<p>$line</p>") >= 0, "$n: summary uses dial's used/free", $line);
	foreach my $d (@dirs) {
		my $x = $fsd{$d};
		my $u = $x->{'total'} - $x->{'free'};
		my $pc = int($u / $x->{'total'} * 100);
		# One table row only: never let the match run on past </tr>.
		my $in = '(?:(?!</tr>).)*?';
		my $row = $out =~ m{<tt>\Q$d\E</tt>$in>\s*\Q${\&nice_size($u)}\E</td>$in>\s*\Q${\&nice_size($x->{'free'})}\E</td>$in>\s*\Q${\&nice_size($x->{'total'})}\E</td>$in>\s*$pc%}s ? 1 : 0;
		check($row, "$d row: used + free = total, $pc%");
		if (!$row) {
			my $i = index($out, "<tt>$d</tt>");
			print "      expected ", &nice_size($u), " / ", &nice_size($x->{'free'}),
			      " / ", &nice_size($x->{'total'}), " / $pc%\n      row: ",
			      ($i < 0 ? "not found" : substr($out, $i, 500)), "\n";
			}
		}
	}
# Who's using it: only filesystems that really have quotas get a table, and
# the figures are the quota system's own (repquota, 1 KB blocks).
check($out !~ m{Biggest users on <tt>/boot</tt>}, "no empty table for /boot (no quotas there)");
my %rq;
foreach my $l (split(/\n/, `repquota -u / 2>/dev/null`)) {
	$rq{$1} = $2 * 1024 if ($l =~ /^(\S+)\s+[-+]{2}\s+(\d+)/);
	}
my @top = (sort { $rq{$b} <=> $rq{$a} } keys %rq)[0 .. 2];
foreach my $u (@top) {
	my $in = '(?:(?!</tr>).)*?';
	my $ok = $out =~ m{>\s*\Q$u\E</td>$in>\s*\Q${\&nice_size($rq{$u})}\E</td>}s ? 1 : 0;
	check($ok, "/ user $u matches repquota", &nice_size($rq{$u}));
	}
# Domain sizes must equal Virtualmin's own "Server byte quota used".
my (%vq, $cur);
foreach my $l (split(/\n/, `virtualmin list-domains --toplevel --multiline 2>/dev/null`)) {
	$cur = $1 if ($l =~ /^(\S+)$/);
	$vq{$cur} = $1 if ($cur && $l =~ /^\s+Server byte quota used:\s+(\d+)/);
	}
my @topd = (sort { $vq{$b} <=> $vq{$a} } grep { $vq{$_} } keys %vq)[0 .. 2];
check(@topd == 3, "Virtualmin reports domain usage", join(' ', @topd));
foreach my $d (@topd) {
	my $in = '(?:(?!</tr>).)*?';
	my $ok = $out =~ m{>\s*\Q$d\E</td>$in>\s*\Q${\&nice_size($vq{$d})}\E</td>}s ? 1 : 0;
	check($ok, "domain $d matches Virtualmin", &nice_size($vq{$d}));
	}
# Bind mounts (a later mount of an already-mounted device) are not listed.
my (%seendev, @bind);
if (open(my $pm, '<', '/proc/mounts')) {
	while (my $l = <$pm>) {
		my ($dev, $dir) = split(/\s+/, $l);
		next if ($dev !~ m{^/dev/});
		push(@bind, $dir) if ($seendev{$dev}++);
		}
	close($pm);
	}
check(@bind && !(grep { index($out, $_) >= 0 } @bind), "bind mount not listed",
      scalar(@bind)." bind mount(s) on this box");
check($out !~ /Biggest users on <tt>\/data/, "no per-user list for the uncounted /data");
print "\nfailures: $fails\n";
exit($fails ? 1 : 0);
