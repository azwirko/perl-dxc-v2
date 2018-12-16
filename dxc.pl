#!/usr/bin/perl

# For Redpitaya & Pavel Demin FT8 code image @ http://pavel-demin.github.io/red-pitaya-notes/sdr-transceiver-ft8

# Gather decodes from FT8 log file /dev/shm/decodes-yymmdd-hhmm.txt file of format 
# 181216 014645  34.7   4 -0.98  7075924 K1RA          FM18

# Uses /dev/shm/decode-ft8.log to determine when above file is ready for decoding

# creates DXCluster like spots available via telnet port 7373
# caches calls up to 5 minutes before respotting (see $MINTIME)

# v0.8.0 - 2018/12/15 - K1RA

# Start by using following command line
# ./dxc.pl YOURCALL YOURGRID
# ./dxc.pl WX1YZ AB12DE

use strict;
use warnings;

use IO::Socket;

# minimum number of minutes to cache calls before resending
my $MINTIME = 5;


# check for YOUR CALL SIGN
if( ! defined( $ARGV[0]) || ( ! ( $ARGV[0] =~ /\w\d+\w/)) ) { 
  die "Enter a valid call sign\n"; 
}
my $mycall = uc( $ARGV[0]);

# check for YOUR GRID SQUARE (6 digit)
if( ! defined( $ARGV[1]) || ( ! ( $ARGV[1] =~ /\w\w\d\d\w\w/)) ) { 
  die "Enter a valid 6 digit grid\n";
} 
my $mygrid = uc( $ARGV[1]);

# DXCluster spot line header
my $prompt = "DX de ".$mycall."-#:";

# holds one single log file line
my $line;

# FT8 fields from FT8 decoder log file
my $msg;
my $date;
my $gmt;
my $x;
my $snr;
my $dt;
my $freq;
my $ft8msg;
my $call;
my $grid;

# decode current and last times
my $time;
my $ltime;

my $decodes;
my $yr;
my $mo;
my $dy;
my $hr;
my $mn;

# hash of deduplicated calls per band
my %db;

# call + base key for %db hash array
my $cb;

# minute counter to buffer decode lines
my $min = 0;

# lookup table to determine base FT8 frequency used to calculate Hz offset
my %basefrq = ( 
  "184" => 1840000,
  "183" => 1840000,
  "357" => 3573000,
  "535" => 5357000,
  "707" => 7074000,
  "1013" => 10136000,
  "1407" => 14074000,
  "1810" => 18100000,
  "1809" => 18100000,
  "2107" => 21074000,
  "2491" => 24915000,
  "2807" => 28074000,
  "5031" => 50313000
);

# used for calculating signal in Hz from base band FT8 frequency
my $base;
my $hz;

# flag to send new spot
my $send;

# fork and sockets
my $pid;
my $main_sock;
my $new_sock;

$| = 1;

$SIG{CHLD} = sub {wait ()};

# listen for telnet connects on port 7373
$main_sock = new IO::Socket::INET ( LocalPort => 7373,
                                    Listen    => 5,
                                    Proto     => 'tcp',
                                    ReuseAddr => 1,
                                  );
die "Socket could not be created. Reason: $!\n" unless ($main_sock);

while(1) {

# Loop waiting for new inbound telnet connections
  while( $new_sock = $main_sock->accept() ) {

    print "New connection - ";
    print $new_sock->peerhost() . "\n";
  
    $pid = fork();
    die "Cannot fork: $!" unless defined( $pid);

    if ($pid == 0) { 
# This is the child process
      print $new_sock $prompt ." FT8 Skimmer >\n\r";
      
# if FT8 log is ready then open
      if( -e "/dev/shm/decode-ft8.log") {
        open( LOG, "tail -f /dev/shm/decode-ft8.log |");
#print "Got it!\n";
      } else {
# test for existence of log file and wait until we find it
        while( ! -e "/dev/shm/decode-ft8.log") {
#print "Waiting 5...\n";
        sleep 5;
      }
      open( LOG, "tail -f /dev/shm/decode-ft8.log |");
#print "Got it!\n";
    }

# Client loop forever
      while(1) {      
#print "Loop \n";      
# setup tail to watch FT8 decoder log file and pipe for reading

# Decoding ...
# Sun Dec 16 01:58:00 UTC 2018
# Recording ...
# Sun Dec 16 01:58:01 UTC 2018
# Sleeping ...
# Done decoding...

# read in lines from FT8 decoder log file 
READ:
        while( $line = <LOG>) {
# check to see if this line says Sleeping
          if( $line =~ /^Done/) { 

# derive time for previous minute to create decode TXT filename
            ($x,$mn,$hr,$dy,$mo,$yr,$x,$x,$x) = gmtime(time-60);
          
            $mo = $mo + 1;
            $yr = $yr - 100;
          
#print "$yr,$mo,$dy,$hr,$mn\n";
          
            $mn = sprintf( "%02d", $mn);
            $hr = sprintf( "%02d", $hr);
            $dy = sprintf( "%02d", $dy);
            $mo = sprintf( "%02d", $mo);
          
# create the filename to read based on latest date/time stamp
            $decodes = "decodes_".$yr.$mo.$dy."_".$hr.$mn.".txt";
#print "$decodes\n";
       
            if( ! -e "/dev/shm/".$decodes) { 
#print "No decode file $decodes\n";            
              next READ; 
            }
            
# open TXT file for the corresponding date/time
            open( TXT,  "< /dev/shm/".$decodes);        

# yes - check if its time to expire calls not seen in $MINTIME window
            if( $min++ > $MINTIME) {

# yes - loop thru cache on call+baseband keys
              foreach $cb ( keys %db) {
# extract last time call was seen        
                ( $ltime) = split( "," , $db{ $cb});

# check if last time seen > $MINTIME        
                if( time() > $ltime + ( $MINTIME * 60) ) {
# yes - purge record
                  delete $db{ $cb};
                } # end if
              } # end foreach
# reset 60 minute timer
              $min = 0;
            } # end if( $min++
    
# loop thru all decodes
MSG:
            while( $msg = <TXT>) {
#print $msg;

# check if this is a valid FT8 decode line beginning with 6 digit time stamp    
# 181216 014645  34.7   4 -0.98  7075924 K1RA          FM18
              if( ! ( $msg =~ /^\d{6}\s\d{6}/) ) { 
# no - go to read next line from decoder log
                next MSG; 
              }

# looks like a valid line split into variable fields
              ($date, $gmt, $x, $snr, $x, $freq, $call, $grid)= split( " ", $msg);
#print "call=$call grid=$grid\n";

# if not a valid call, skip this msg
              if( ( $call eq "") || ( ! ( $call =~ /\d/) ) ) { next MSG; }

# clear grid if undefined
              if( $grid eq "") { $grid = "    "; }

# extract HHMM
              $gmt =~ /^(\d\d\d\d)\d\d/;
              $gmt = $1;
    
# get UNIX time since epoch  
              $time = time();
    
# determine base frequency for this FT8 band decode    
              $base = int( $freq / 10000);

# make freq an integer  
              $freq += 0;

# check cache if we have NOT seen this call on this band yet  
              if( ! defined( $db{ $call.$base}) ) { 
# yes - set flag to send it to client(s) 
                $send = 1;

# save to hash array using a key of call+baseband 
                $db{ $call.$base} = $time.",".$call.",".$grid.",".$freq.",".$snr;
              } else {
# no - we have seen call before, so get last time call was sent to client
                ( $ltime) = split( ",", $db{ $call.$base});
      
# test if current time is > first time seen + MINTIME since we last sent to client
                if( time() >= $ltime + ( $MINTIME* 60) ) {
# yes - set flag to send it to client(s) 
                  $send = 1;

# resave to hash array with new time
                  $db{ $call.$base} = $time.",".$call.",".$grid.",".$freq.",".$snr;
                } else {
# no - don't resend or touch time 
                  $send = 0;
                }
              } # end if( ! defined - cache check

# make sure call has at least one number in it
              if ( $call =~ /\d/ && $send ) {
                $hz = $freq - $basefrq{ $base};

if( !defined( $base) ) { print "$call $base\n"; }

# send client a spot
# DX de K1RA-#:    14074.8 5Q0X       FT8  -3 dB 1234 Hz JO54           1737z
                printf $new_sock "%-15s %8.1f  %-12s FT8 %3s dB %4s Hz %4s      %6sZ\n\r",$prompt,$basefrq{ $base}/1000,$call,$snr,$hz,$grid,$gmt;
              }
      
            } # end while( $msg = <MSG> - end of reading MSGs

          } # end if( $line =~ /^Done/ - end of a FT8 log decoder minute capture

          die "Socket is closed" unless $new_sock->connected;
        } # end while( $line = <LOG> - end of FT8 decode LOG file
        
      } # end while(1) - loop client forever
    
    } # end if( $pid == 0) - its the parent process, which goes back to accept()

  } # end while( $new_sock - main wait for socket loop forever

} # end while (1)

