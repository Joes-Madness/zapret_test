#!/usr/bin/perl -w

#use LWP::Simple;
use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request::Common qw(GET);
use DBI;
use utf8;
use Config::Simple;
use Log::Log4perl;
use threads;
use Thread::Queue;
use Date::Parse;

binmode(STDOUT,':utf8');
binmode(STDERR,':utf8');

######### Config #########

my $dir = File::Basename::dirname($0);
my $Config = {};

my $config_file=$dir.'/zapret_test.conf';
my $log_file=$dir."/zapret_test_log.conf";

Config::Simple->import_from($config_file, $Config) or die "Can't open ".$config_file." for reading!\n";

Log::Log4perl::init( $log_file );

my $logger=Log::Log4perl->get_logger();

my $db_host = $Config->{'DB.host'} || die "DB.host not defined.";
my $db_user = $Config->{'DB.user'} || die "DB.user not defined.";
my $db_pass = $Config->{'DB.password'} || die "DB.password not defined.";
my $db_name = $Config->{'DB.name'} || die "DB.name not defined.";

my $threads = $Config->{'APP.threads'} || 10;
my $substring = $Config->{'APP.substring'} || die "APP.substring not defined.";
my $log_rate = $Config->{'APP.log_rate'} || 100;

my $ua = LWP::UserAgent->new;

my $Q = new Thread::Queue;

######### End Config #########

my $start_time = localtime();

$logger->info("Starting zapret test at ".$start_time);

my @threads;
#my $threads=20;

unlink glob 'reports/*';

open REPORT, '>reports/report';

my $dsn = 'DBI:mysql:'.$db_name.':'.$db_host;
my $dbh = DBI->connect($dsn, $db_user, $db_pass, {mysql_enable_utf8 => 1,} ) or die DBI->errstr;
my $urlCount:shared = 0;
my $urlFail:shared = 0;
my $sth = $dbh->prepare(qq{
	select url from zap2_urls
});
$sth->execute();
my $rowCount = $sth->rows;

for my $t (1..$threads) {
	push @threads, threads->create(\&thread, $Q, $t);
}

while( my $ref = $sth->fetchrow_hashref() ) {
	#print "\n", $ref, "\n";
	$Q->enqueue( join $;, %$ref );
	sleep 1 while $Q->pending > 100;
}

$Q->end();

foreach my $t (@threads) {
	$t->join();
}

$sth->finish();
$dbh->disconnect();

print qq(URL count: $urlCount\n);
print qq(URL failed: $urlFail);
$logger->info("URL count: ".$urlCount);
$logger->info("URL failed: ".$urlFail);
my $percent = $urlFail / $urlCount;
$logger->info("Failed in percent: ".$percent."%");
my $stop_time = localtime();
$logger->info("Stopping zapret test at ".$stop_time);

print REPORT "Count: ", $urlCount, "\n";
print REPORT "Fail: ", $urlFail, "\n";
close REPORT;

exit 0;

sub thread {
	my ( $Q, $t ) = @_;
	while( my ($nam, $url) = split $;, $Q->dequeue ) {
		checkUrl($url);
		my $urlNum = ++$urlCount;
		if ($urlNum % $log_rate == 0) {
			$logger->info("Checked ".$urlNum."/".$rowCount);
		}
	}
}

sub checkUrl {
	my $url = shift;
	my $req = GET $url;
	my $res = $ua->request($req);
	if ($res->is_success) {
		if ($res->content =~ /\Q$substring\E/) {
			return;
		} else {
			my $num = ++$urlFail;
			open CONTENT, '>reports/'.$num;
			print CONTENT $res->content;
			close CONTENT;
			print REPORT $num, "\t", $url, "\n";
			$logger->error("URL not blocked: ".$url);
		}
	}
}
