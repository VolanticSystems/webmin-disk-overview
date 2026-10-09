#!/usr/bin/perl
# test-dial-route.pl - checks the route from the dashboard disk dial to the
# disk page, using Webmin's own functions as root. Read-only.
#   - the theme sends the dial to /disk-usage only if foreign_available says so
#   - the hidden flag must keep it out of the menu
#   - disk-usage/index.cgi must redirect to /disk-focus/
#   - the dashboard panel must follow the dial's setting (/ and /boot)
BEGIN {
	push(@INC, "/usr/libexec/webmin");
	$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
	$ENV{'WEBMIN_VAR'} = '/var/webmin';
	$ENV{'REMOTE_USER'} = $ENV{'BASE_REMOTE_USER'} = 'root';
	$0 = "/usr/libexec/webmin/disk-focus/index.cgi";
}
use WebminCore;
chdir("/usr/libexec/webmin/disk-focus");
&init_config();
my $fails = 0;
sub check { my ($ok, $l, $d) = @_; printf("%s  %-56s %s\n", $ok ? 'PASS' : 'FAIL', $l, $d || ''); $fails++ if (!$ok); }

check(&foreign_available("disk-usage") ? 1 : 0, "disk-usage available to root (theme will route the dial)");
check(&foreign_available("quota") ? 1 : 0, "Disk Quotas still available (menu and page link)");
my @vis = map { $_->{'dir'} } &get_visible_module_infos(1);
check((grep { $_ eq 'disk-usage' } @vis) ? 0 : 1, "disk-usage hidden from the menu");
check((grep { $_ eq 'disk-focus' } @vis) ? 1 : 0, "Primary Disk Usage still in the menu");

my $out = `cd /usr/libexec/webmin/disk-usage && WEBMIN_CONFIG=/etc/webmin WEBMIN_VAR=/var/webmin REMOTE_USER=root SERVER_NAME=localhost SERVER_PORT=10000 HTTPS=ON perl -I/usr/libexec/webmin /usr/libexec/webmin/disk-usage/index.cgi 2>&1`;
my ($loc) = $out =~ /^Location:\s*(\S+)/mi;
if (!$loc && $out =~ /authentic-theme/) {
	# &redirect hands off to the theme, which needs a live browser session.
	# Same call as Webmin's own proc/index.cgi. Not decidable here: say so.
	printf("SKIP  %-56s %s\n", "disk-usage redirects to /disk-focus/",
	       "theme needs a browser session; check by clicking the dial");
	}
else {
	check(($loc || '') =~ m{/disk-focus/$} ? 1 : 0, "disk-usage redirects to /disk-focus/", $loc || substr($out, 0, 80));
	}

&foreign_require("disk-focus", "disk-focus-lib.pl");
my @d = map { $_->{'dir'} } &disk_focus::list_focus_disks();
my %vc = &foreign_config("virtual-server");
my $want = collect_fs::wanted_dirs($vc{'collect_fs'} || '');
my @exp = $want ? sort keys %$want : ();
check(!$want || "@{[sort @d]}" eq "@exp", "dashboard panel follows the dial setting", "@d (setting wants @exp)");

# After Save, Webmin returns to /virtual-server/ + _cscript; the badge passes
# _cscript=../disk-focus/ so that must land on the disk page.
do "/usr/libexec/webmin/config-lib.pl";
my $back = &link_config_cparams("virtual-server", { '_cscript' => '../disk-focus/' });
check($back eq "/virtual-server/../disk-focus/", "Save returns to the disk page", $back);
print "\nfailures: $fails\n";
exit($fails ? 1 : 0);
