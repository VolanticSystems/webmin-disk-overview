#!/usr/bin/perl
# test-collect-fs.pl - checks collect-fs-lib.pl against this machine's real
# drives and against synthetic disk_fs data. Read-only: changes nothing.
use strict;
use warnings;
my $dir = $ARGV[0] || '/usr/libexec/webmin/disk-focus';
do "$dir/collect-fs-lib.pl" or die "load: $@ $!";

my $fail = 0;
sub check { my ($ok, $label) = @_; print(($ok ? "PASS" : "FAIL"), "  $label\n"); $fail++ if (!$ok); }

print "Drives found:\n";
foreach my $d (collect_fs::list_drives()) {
	printf "  %-8s %-28s %8s %s  on: %s\n", $d->{'name'}, $d->{'model'},
		collect_fs::nice($d->{'bytes'}), $d->{'ssd'} ? 'SSD' : 'HDD',
		join(', ', @{$d->{'mounts'}}) || '-';
	}

my $w = collect_fs::wanted_dirs('disks:nvme0n1 nvme1n1');
check($w && $w->{'/'} && $w->{'/boot'} && !$w->{'/data'},
      "both NVMe drives -> / and /boot, not /data");
$w = collect_fs::wanted_dirs('disks:sda');
check($w && $w->{'/data'} && !$w->{'/'}, "sda -> /data only");
$w = collect_fs::wanted_dirs('disks:nvme0n1');
check($w && !$w->{'/'}, "one NVMe of a mirrored pair -> / not counted (needs every drive under it)");
check(!defined(collect_fs::wanted_dirs('')), "empty -> all (undef)");
$w = collect_fs::wanted_dirs('/ /boot');
check($w && $w->{'/'} && $w->{'/boot'} && !$w->{'/data'}, "mount list '/ /boot'");

my $mk = sub { { 'disk_total' => 300, 'disk_free' => 150, 'disk_used' => 150,
		 'disk_fs' => [ { 'dir' => '/',     'total' => 100, 'free' => 60,  'used' => 40 },
				{ 'dir' => '/boot', 'total' => 10,  'free' => 5,   'used' => 5 },
				{ 'dir' => '/data', 'total' => 190, 'free' => 85,  'used' => 105 } ] } };
my $i = $mk->(); collect_fs::apply($i, '/');
check($i->{'disk_total'} == 100 && $i->{'disk_free'} == 60 && $i->{'disk_used'} == 40,
      "apply '/' -> totals of / only");
check(scalar(@{$i->{'disk_fs'}}) == 3, "apply keeps the full per-filesystem list");
$i = $mk->(); collect_fs::apply($i, '');
check($i->{'disk_total'} == 300, "apply '' -> stock totals untouched");
$i = $mk->(); collect_fs::apply($i, '/nonexistent');
check($i->{'disk_total'} == 300 && $i->{'disk_filter_error'}, "no match -> stock totals kept, error recorded");

check(eval { collect_fs::form_value({ 'collect_fs_mode' => 'disks', 'collect_fs_disks' => "nvme0n1\0nvme1n1" }) } eq 'disks:nvme0n1 nvme1n1',
      "form: two drives -> 'disks:nvme0n1 nvme1n1'");
check(eval { collect_fs::form_value({ 'collect_fs_mode' => 'dirs', 'collect_fs_dirs' => ' / /boot ' }) } eq '/ /boot',
      "form: mount list trimmed");
check(eval { collect_fs::form_value({ 'collect_fs_mode' => 'all' }) } eq '', "form: all -> ''");
check(!defined(eval { collect_fs::form_value({ 'collect_fs_mode' => 'disks', 'collect_fs_disks' => 'sdz' }) }),
      "form: unknown drive refused");
check(!defined(eval { collect_fs::form_value({ 'collect_fs_mode' => 'dirs', 'collect_fs_dirs' => 'data' }) }),
      "form: relative path refused");
print "Storage groups:\n";
my @g = collect_fs::list_groups();
foreach my $e (@g) {
	printf "  %-20s %s  on: %s\n", join(' + ', @{$e->{'names'}}), $e->{'ssd'} ? 'SSD' : 'HDD',
		join(', ', map { $_->[0].($_->[1] ? " ($_->[1])" : '') } @{$e->{'mounts'}}) || '-';
	}
my ($nv) = grep { "@{$_->{'names'}}" eq 'nvme0n1 nvme1n1' } @g;
my ($sd) = grep { "@{$_->{'names'}}" eq 'sda' } @g;
check(@g == 2 && $nv && $sd, "two storage groups: the NVMe pair as one, sda alone");
check($nv && (grep { $_->[0] eq '/' && $_->[1] eq 'RAID0' } @{$nv->{'mounts'}})
	  && (grep { $_->[0] eq '/boot' && $_->[1] eq 'RAID1' } @{$nv->{'mounts'}}),
      "NVMe group labels / as RAID0 and /boot as RAID1");
# Bind mounts: every later mount of an already-mounted device.
my (%seendev, @bind);
if (open(my $pm, '<', '/proc/mounts')) {
	while (my $l = <$pm>) {
		my ($dev, $dir) = split(/\s+/, $l);
		next if ($dev !~ m{^/dev/});
		push(@bind, $dir) if ($seendev{$dev}++);
		}
	close($pm);
	}
check(@bind > 0, "this box has a bind mount to test with (".scalar(@bind)." found)");
check($sd && @{$sd->{'mounts'}} == 1 && $sd->{'mounts'}[0][0] eq '/data',
      "sda shows /data once; its bind mount is not listed");
check(eval { collect_fs::form_value({ 'collect_fs_mode' => 'disks', 'collect_fs_disks' => "nvme0n1 nvme1n1\0sda" }) } eq 'disks:nvme0n1 nvme1n1 sda',
      "form: two group entries -> all three drives");
my $html = collect_fs::show_field('disks:nvme0n1 nvme1n1');
check($html =~ /value="nvme0n1 nvme1n1" selected/ && $html =~ /value="sda">/ && $html =~ /value=disks checked/,
      "form renders the NVMe pair as one pre-selected entry, sda unselected");
check(!(grep { index($html, $_) >= 0 } @bind), "form does not show the bind mount");

# Saving must drop the theme's dashboard cache, and nothing else. Done in a
# throwaway folder so the real cache is left alone.
use File::Temp qw(tempdir);
my $tmp = tempdir("collectfs-cache-test-XXXXXX", TMPDIR => 1, CLEANUP => 1);
foreach my $f ("combined-system-info-root", "combined-system-info-admin", "other-cache") {
	open(my $fh, ">", "$tmp/$f") || die "$tmp/$f: $!"; close($fh);
	}
my $gone = collect_fs::forget_dashboard_cache($tmp);
check($gone == 2 && !-e "$tmp/combined-system-info-root" && !-e "$tmp/combined-system-info-admin"
	&& -e "$tmp/other-cache", "save drops every user's dashboard cache and leaves other files");

print $fail ? "$fail FAILED\n" : "all passed\n";
exit($fail ? 1 : 0);
