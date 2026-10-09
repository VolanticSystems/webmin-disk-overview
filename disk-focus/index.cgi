#!/usr/bin/perl
# Disk page for Primary Disk Usage: where the dashboard disk dial lands.
#
# Two tabs, so a click on the dial answers the questions that follow a disk
# looking full:
#   Storage          - how full is each storage group, and which does the dial
#                      count; its Counted / Not counted badge opens the setting
#   Who's using it   - the biggest users and Virtualmin domains on that storage
#
# Storage is grouped (collect-fs-lib.pl list_groups): drives used together, such
# as fsn1's RAID 0 NVMe pair, are one entry, because half of a striped pair is
# not something you can choose. SSD/HDD comes from the kernel's rotational flag.
# The dial reaches this page through the hidden 'disk-usage' module, which the
# theme already prefers over Disk Quotas for the disk dial. (fsn1, 2026-10-08)

require './disk-focus-lib.pl';
require './collect-fs-lib.pl';
&ReadParse();

my %vc;
%vc = &foreign_config("virtual-server") if (&foreign_check("virtual-server"));
my $setting = $vc{'collect_fs'} || '';

&foreign_require("mount");
my (undef, undef, $allfs, undef) = &mount::local_disk_space();
my %fs = map { $_->{'dir'}, $_ } @$allfs;
my $want = &dial_counted_dirs($setting, \%fs);	# undef = everything counted
my $counted = sub { !$want || $want->{$_[0]} };
my @groups = collect_fs::list_groups();

&ui_print_header(undef, $text{'index_title'}, "", undef, 0, 1);
# Back to the dashboard the dial was clicked on (Virtualmin's, as on fsn1).
my $dash = &foreign_available("virtual-server") ? "/sysinfo.cgi?mod=virtual-server"
						 : "/sysinfo.cgi";
print "<p><a class='btn btn-default' href='$dash'>&larr; Back to dashboard</a></p>\n";

my $mode = $in{'mode'} || 'storage';
my @tabs = ( [ 'storage',  'Storage' ],
	     [ 'users',    "Who's using it" ] );
# The badges open Virtualmin's Status collection settings, where
# "Filesystems to include in local disk space" decides what the dial counts.
my $can_set = &foreign_available("virtual-server");
print &ui_tabs_start(\@tabs, 'mode', $mode, 1);

# ------------------------------------------------------------------- storage
print &ui_tabs_start_tab('mode', 'storage');
print "<p><b>The dial counts</b> ", &describe_setting($setting, \@groups),
      ($can_set ? " Click a <i>Counted</i> or <i>Not counted</i> badge to change it." : ""),
      "</p>\n";
foreach my $g (@groups) {
	my @m = grep { $fs{$_->[0]} } @{$g->{'mounts'}};
	next if (!@m);
	my ($t, $u) = (0, 0);
	foreach my $x (@m) {
		$t += $fs{$x->[0]}->{'total'};
		$u += &used_of($fs{$x->[0]});
		}
	my $on = !grep { !$counted->($_->[0]) } @m;
	my $badge = &dial_badge($on);
	print "<h3>", &group_title($g), " &nbsp;$badge</h3>\n";
	print &usage_bar($t ? int($u / $t * 100) : 0),
	      "<p>", &nice_size($u), " of ", &nice_size($t), " used, ",
	      &nice_size($t - $u), " free</p>\n";
	print &ui_columns_start([ 'Mount point', 'Layout', 'Type', 'Used',
				  'Free', 'Total', 'Used %' ]);
	foreach my $x (@m) {
		my $f = $fs{$x->[0]};
		my $used = &used_of($f);
		my $pc = $f->{'total'} ? int($used / $f->{'total'} * 100) : 0;
		print &ui_columns_row([
			"<tt>".&html_escape($x->[0])."</tt>",
			$x->[1] ? &raid_label($x->[1]) : 'single drive',
			$f->{'type'}, &nice_size($used), &nice_size($f->{'free'}),
			&nice_size($f->{'total'}), &pc_text($pc) ]);
		}
	print &ui_columns_end();
	}
print &ui_tabs_end_tab('mode', 'storage');

# --------------------------------------------------------------------- users
print &ui_tabs_start_tab('mode', 'users');
my @dirs = grep { $counted->($_) } map { $_->{'dir'} } @$allfs;
print "<p>Who is using the storage the dial counts (",
      join(', ', map { "<tt>".&html_escape($_)."</tt>" } @dirs), ").</p>\n";

my $shown = 0;
if (&foreign_available("quota")) {
	&foreign_require("quota");
	foreach my $d (@dirs) {
		# filesystem_users returns -1 when the filesystem has no quotas
		# (e.g. /boot); that used to print an empty table and a dead link.
		my $n = eval { &quota::filesystem_users($d) } || 0;
		next if ($n <= 0);
		my @u;
		for (my $i = 0; $i < $n; $i++) {
			push(@u, [ $quota::user{$i,'user'},
				   ($quota::user{$i,'ublocks'} || 0) * 1024 ]);
			}
		@u = (sort { $b->[1] <=> $a->[1] } @u)[0 .. ($#u < 9 ? $#u : 9)];
		print "<h3>Biggest users on <tt>", &html_escape($d), "</tt></h3>\n";
		print &ui_columns_start([ 'User', 'Space used', 'Share of filesystem' ]);
		my $tot = $fs{$d}->{'total'} || 1;
		foreach my $x (@u) {
			print &ui_columns_row([ &html_escape($x->[0]),
				&nice_size($x->[1]),
				sprintf("%.1f%%", $x->[1] * 100 / $tot) ]);
			}
		print &ui_columns_end();
		print "<p>", &ui_link("../quota/list_users.cgi?dir=".&urlize($d),
			"Full list in Disk Quotas for ".&html_escape($d)), "</p>\n";
		$shown++;
		}
	}
if (&foreign_available("virtual-server")) {
	&foreign_require("virtual-server");
	my $bs = &virtual_server::quota_bsize("home");
	my @d;
	foreach my $dom (grep { !$_->{'parent'} } &virtual_server::list_domains()) {
		my ($home) = eval { &virtual_server::get_domain_quota($dom) };
		push(@d, [ $dom->{'dom'}, ($home || 0) * $bs ]) if ($home);
		}
	if (@d) {
		@d = (sort { $b->[1] <=> $a->[1] } @d)[0 .. ($#d < 9 ? $#d : 9)];
		print "<h3>Biggest Virtualmin domains (home directories, including sub-servers)</h3>\n";
		print &ui_columns_start([ 'Domain', 'Space used' ]);
		print &ui_columns_row([ &html_escape($_->[0]), &nice_size($_->[1]) ])
			foreach (@d);
		print &ui_columns_end();
		$shown++;
		}
	}
print "<p>No per-user or per-domain usage is available for this storage. ",
      "Quotas may be switched off.</p>\n" if (!$shown);
print &ui_tabs_end_tab('mode', 'users');

print &ui_tabs_end(1);
&ui_print_footer($dash, "dashboard");

# ----------------------------------------------------------------- helpers
# Used is total minus free, as the dashboard dial counts it, so the blocks
# reserved for root count as used and used + free = total. Taking the
# filesystem's own 'used' figure counted the reserve as free and made this
# page read about 5 points emptier than the dial (37% vs 42% on fsn1).
sub used_of
{
my ($f) = @_;
return $f->{'total'} - $f->{'free'};
}

sub group_title
{
my ($g) = @_;
my @d = @{$g->{'drives'}};
my %sz = map { collect_fs::nice($_->{'bytes'}), 1 } @d;
my $size = keys(%sz) == 1 && @d > 1
	? scalar(@d)." &times; ".(keys %sz)[0]
	: join(' + ', map { collect_fs::nice($_->{'bytes'}) } @d);
return &html_escape(join(' + ', @{$g->{'names'}}))." &mdash; ".
       &html_escape(join(' + ', map { $_->{'model'} } @d)).", $size ".
       ($g->{'ssd'} ? 'SSD' : 'HDD');
}

sub dial_badge
{
my ($on) = @_;
my ($cls, $txt) = $on ? ('label-success', 'Counted on the dashboard dial')
		      : ('label-default', 'Not counted on the dial');
return "<span class='label $cls'>$txt</span>" if (!$can_set);
# _cscript is Webmin's own "come back here" parameter: config.cgi carries it
# through the form, and both Save and the bottom link go to
# /virtual-server/ + _cscript, which resolves to this page.
return "<a class='label $cls' href='../config.cgi?module=virtual-server&amp;section=line7".
       "&amp;_cscript=..%2Fdisk-focus%2F' ".
       "title='Change what the dial counts'>$txt</a>";
}

sub raid_label
{
my ($r) = @_;
my %why = ( 'RAID0' => 'striped, no redundancy',
	    'RAID1' => 'mirrored' );
return &html_escape($r).($why{$r} ? " ($why{$r})" : '');
}

sub describe_setting
{
my ($v, $groups) = @_;
my ($mode, @list) = collect_fs::parse_value($v);
return "all local filesystems (Webmin's default)." if ($mode eq 'all');
return "all local filesystems, because none of the storage chosen in its ".
       "setting is mounted." if (!$want);
return "only the mount points ".join(', ', map { "<tt>".&html_escape($_)."</tt>" } @list)."."
	if ($mode eq 'dirs');
my %sel = map { $_, 1 } @list;
my @names = map { &group_title($_) }
	    grep { my $g = $_; !grep { !$sel{$_} } @{$g->{'names'}} } @$groups;
return "only the storage ".join('; ', @names).".";
}

sub pc_text
{
my ($pc) = @_;
return $pc >= 90 ? "<font color=#cc0000><b>$pc%</b></font>"
     : $pc >= 75 ? "<font color=#cc7700>$pc%</font>" : "$pc%";
}

sub usage_bar
{
my ($pc) = @_;
my $col = $pc >= 90 ? '#cc0000' : $pc >= 75 ? '#cc7700' : '#3a7';
return "<div style='max-width:40em;height:14px;background:#ddd;border-radius:3px'>".
       "<div style='width:$pc%;height:14px;background:$col;border-radius:3px'></div></div>";
}
