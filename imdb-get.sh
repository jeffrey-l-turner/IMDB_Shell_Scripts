#!/bin/sh
# imdb-get gets current IMDB.COM data for a given studio with optional date range
# Copyright (c) 2012 InterStream LLC All Rights Reserved.
# outputs to stdout by default or filename as option 
# Date range defaults to entire list from database if not specified
# Will process up to 20,000 items / can set higher by change MAX env variable
#########################################################
#   Script Requirements
#
#   Programs:
#	curl
#	getopt
#	date
#	awk
#	sed
#	tail
#	cut
#	dirname
#	basename
#	rm
#	mv
#	wc
#	cat
#########################################################

#########################################################
# Usage: imdb-get [-h] [-q] [-a] -s <studio_name> [-d <date_range>] [-o <output_file>]]
#########################################################

#########################################################
# Process:
#   Set Environment Variables
#   Read command line switches
#   Process special case studio names and production companies via testing IMDB URLs
#   Get first page with curl
#   Parse first page to extract data and find number of items
#   Get all subsequent pages using curl; append them to $TMPFILE
#   Normalize output of $TMPFILE to stdout or designated file
#   
# Portability:
#   To Strip HTML, we'll use "sed 's/<[^>]*>//g'"
#   To translate special character codes into hex we'll use
#       "| sed 's/&#x27;/`echo \047`/g' | sed 's/&#x26;/\&/g' | sed 's/&#xF3;/o/g'"
#	   -- note the use of the `echo \047`
#	   -- must use this approach because BSD/OS X has a very old sed; 
#	   -- it doesn't interpret hex escapes properly; have not checked portability to Linux or other OSes
########################################################

#########################################################
# setup variables
#
# DATE_RANGE  - Date Range to be processed (all dates default)
# DATE_START  - Oldest date in IMDB database 
# STUDIO      - Studio Names for fetch from IMDB database
# o, "OUTPUTFILE" - File for Output; if none specified stdout will be used 
# TMPFILE      - Location & Name of Temp File
# MAX	      - Maximum number of entries to process
# QUIET	      - Sets stderr option on curl for quiet mode
#
#########################################################

declare -i CUR_YEAR=`date | cut -d' ' -f6`
declare -i DATE_START=1915
DATE=`date +%m%d%Y%s`
CUR_DIR=`dirname $0`
TMPFOLDER=/tmp
CANONIMDBURL='http://www.imdb.com/search/title?&companies='
MAX=20000
QUIET=""
STRIP="1"

# command line options:
declare -i s=0
declare -i d=0
declare -i a=0
o='/' 
QUERYDATE="$DATE_START,$CUR_YEAR"
 
#########################################################
# setup some useful error handling functions
#########################################################
 
usage() {
 	echo `basename $0`: ERROR: $* 1>&2
 	echo usage: `basename $0` '[-h] [-q] [-r] [-a] -s studio [-d date_range ] [-o file]' 1>&2
 	echo 'where: date_range is two years separated by a single comma and of the form YYYY,YYYY' 1>&2
 	echo 'using quiet mode, -q, will overwrite existing files specified by -o without warning & suppress progress information.' 1>&2
 	echo 'using raw mode, -r, will output without stripping extraneous data.' 1>&2
 	echo 'using append mode, -a, will append to the file specified by -o as well as remove leading numerical identifiers' 1>&2
 	exit 1
}
 
cleanup() {
 	rm -f "$TMPFILE.items" "$TMPFILE" "$TMPFILE.tmp" "$TMPFILE.tmp-proc" 
}
 
error() {
 	cleanup
 	echo `basename $0`: ERROR: $* 1>&2
 	echo "shuting down... internal error or unable to connect to Internet" 1>&2
 	exit 2
}

interrupt () {
 	cleanup
 	echo `basename $0`: INTERRUPTED: $* 1>&2
 	echo "Cleaning up... removed files" 1>&2
 	exit 2
}
 
trap error TERM 
trap interrupt INT  
 
#########################################################
# read command line switches
#########################################################

set -- `getopt "hqras:d:o:" "$@"` || usage 
set -o errexit


while :
do
        case "$1" in
        -h) usage;;
        -q) QUIET="-s";;
        -r) STRIP="0";;
        -s) s=1;
	    shift;
	    STUDIO=`echo "$1" | tr "[:upper:]" "[:lower:]"`;;
        -d) d=1;
	    shift;
	    QUERYDATE="$1";;
        -o) shift; o="$1";;
        -a) a=1;;
        --) break;;
	*) usage;;
        esac
        shift
done
shift $(($OPTIND - 1))



if [ "$o" != "/" ] && [ "$a" -eq 1 ] && [ "$QUIET" != "-s" ]; then
	echo "-o ond -a set; will format without item numbers and append to file"
fi

# Check to make sure -s option is set
if [ "$s" != 1 ]; then
	echo "-s option must be set" 1>&2
	echo "note: Studio should be one of warner, fox, pbs, lionsgate, universal, sony, dreamworks, disney, paramount, own, natgeo, cbs, lucas, ufc, hdnet, aetv, or mgm." 1>&2
	echo "note: If studio does not match one of the above, the company id will be used in the query to IMDB. The format should be coXXXXXX, where Xs are numbers." 1>&2
	usage;
fi

# Check to make sure date range is set properly
if [ "$d" -eq 1 ]; then
	declare -i DATE1=`echo $QUERYDATE | sed "s/,/ /" | cut -d' ' -f 1`
	declare -i DATE2=`echo $QUERYDATE | sed "s/,/ /" | cut -d' ' -f 2`
	echo "Checking Date Range..."
	echo "Date1 = $DATE1; Date2 =  $DATE2"

if [ "$DATE2" -gt "$CUR_YEAR" ] || [ "$DATE1" -lt "$DATE_START" ] || [ "$DATE2" -lt "$DATE1" ]; then 
	echo "Date range improperly set - must of of the form YYYY,YYYY where first year is not earlier than $DATE_START, and second year not later than $CUR_YEAR" 1>&2
	usage;
fi
fi


# Some studios and production companies are "special cases"; can add production or distribution company codes here by looking at URL format from IMDB
case "$STUDIO" in
	sony) STUDIO="columbia";;     # Sony is formerly Columbia; IMDB uses that designation
	cbs) STUDIO="co0274041";;
        lucas) STUDIO="co0071326";;
        ufc) STUDIO="co0147548";;
	lionsgate) STUDIO="co0026995";;
	hdnet) STUDIO="co0094788";;
	own) STUDIO="co0229287";;
	natgeo) STUDIO="co0139461";;
	aetv) STUDIO="co0056790";;
	pbs) STUDIO="co0039462";;
esac

# Set tmp file using unique identifier from date/time, current PID and studio
TMPFILE="$TMPFOLDER/imdb-get-$$-$STUDIO.$DATE"

if [ "$QUIET" != "-s" ]; then
	echo "IMDB Studio Identifier is $STUDIO"
fi

# Get initial data from IMDB for first 100 entries
set +e
curl $QUIET -L -o "$TMPFILE" "$CANONIMDBURL$STUDIO&release_date=$QUERYDATE&view=simple" || error;
set -o errexit

# Parse number of items from returned HTML and assign from 2nd to last line to environment variable $ITEMS
cat "$TMPFILE" | awk '/Most Popular/ , /title/' | sed 's/<[^>]*>//g' | tail +11 > "$TMPFILE.items" 

	# Parse ITEMSTR by grepping second to last line of file; if no of then take individual from file
	ITEMSTR=`fgrep of "$TMPFILE.items" | cut -d " " -f 3`
if [ "$ITEMSTR" = "" ]; then
	ITEMSTR=`tail -2 "$TMPFILE.items" | paste -s -d '\t' - | cut -f1`
fi

if [ "$QUIET" != "-s" ]; then
	echo
	echo "Processing $ITEMSTR items..."
	echo
fi

# Do some formatting so numerical expressions don't complain later
ITEMS=`echo $ITEMSTR | sed s/,//g`


# Do a sanity check...
if [ $ITEMS -ge $MAX ]; then
	echo "Found $ITEMS in IMDB Database for query"
	echo "Too many items to process... aborting"
	echo "This is most likely caused by a bad IMDB database query"
	echo "Check your studio name or IMDB company code carefully!"
	cleanup
	usage
fi


# Begin parsing data and create additional temporary file from existing HTML temporary file; append to file with additional data
# Awk to get data between header "results and the table identifier signifying end of results; strip HTML using sed, then cut off first 11 lines

cat "$TMPFILE" | awk '/<table class="results">/ , /<\/table>/' | sed 's/<[^>]*>//g' | tail +11 > "$TMPFILE.tmp" 

# Process # of $ITEMS in while loop and append to .tmp file

if [ "$ITEMS" '>' 100 ]; then
	CURITEM=`expr 100 + 1`
while [ $CURITEM -le $ITEMS ]
do
		rm $TMPFILE
		set +e
		curl $QUIET -L -o "$TMPFILE" "$CANONIMDBURL$STUDIO&release_date=$QUERYDATE&start=$CURITEM&view=simple" || error;
		set -o errexit
		cat "$TMPFILE" | awk '/<table class="results">/ , /<\/table>/' | sed 's/<[^>]*>//g' | tail +11 >> "$TMPFILE.tmp" 
		CURITEM=`expr $CURITEM + 100`
done
fi

if [ "$QUIET" = "" ]; then
	echo "$ITEMS entries processed"
fi

# Test for "raw" output
# Remove extraeneous information -- ratings, individual dashes (-) etc by printing up to first newline after item number designator and then format with sed for control characters
if [ "$STRIP" -eq 1 ]; then
	awk 'BEGIN {ORS="\n";OFS="\t";x="0"} /^[0-9]*\.$/ {print"\n";print;x=1;next} /^.*[:graph:]*$/ {if(x)print} /^$/ {x="";next}' $TMPFILE.tmp | sed -e "s/&#x27;/`echo "\047"`/g" -e 's/&#x26;/\&/g' -e 's/&#xF3;/o/g'   > $TMPFILE.tmp-proc

	# Strip leading item identifiers if we have -a
if [ "$a" -eq 1 ]; then
	awk 'BEGIN {RS="\n\n";FS="^[0-9]*\.$";ORS="";OFS ="\t";x="0"} /^[0-9]*\.$/ {print"\n";x=1;next} /^.*[:graph:]*$/ {if(x)print} /^$/ {x="";next}' "$TMPFILE.tmp-proc" > "$TMPFILE.tmp"
else
	mv "$TMPFILE.tmp-proc" "$TMPFILE.tmp"
fi
fi

# Determine whether to write file to stdout append, or create file
if [ "$o" = "/" ]; then
	cat "$TMPFILE.tmp" 
else

if [ "$QUIET" = "-s" ] && [ "$a" -eq 0 ]; then
	mv -f "$TMPFILE.tmp" "$o"
	
else

if [ "$a" -eq 1 ]; then
	cat "$TMPFILE.tmp" >> "$o"
else
	mv -i "$TMPFILE.tmp" "$o"
fi

fi
fi

# Cleanup tmp files
cleanup

exit 0

# These are some useful pipelines I may want to use...
#  sed -e '$!N; /^\(.*\)\n\1$/!P; D' -e 's/^[ \t]*//' -e 's/^-//g' -e 's/[1-9]\.[0-9]\/10//g' -e "s/&#x27;/`echo "\047"`/g" -e 's/&#x26;/\&/g' -e 's/&#xF3;/o/g' $TMPFILE.tmp 
#   | awk '/^$/ {x="";getline;next} {if(x)print x;x=$0} END{if(x)print x}' > $TMPFILE.tmp-proc
