#!/bin/sh

PROJECT=`basename $0`

usage()
{
	echo "usage: $PROJECT name [file...]" >&2
	exit 1
}

NAME=$1
test "$NAME" != "" || usage
shift

P=`go env GOPATH`/src/github.com/anton2920/$NAME
while test "$#" -gt "0"; do
	if test -d "$P/$1"; then
		find $P/$1 -type f -depth 1 | grep -v '\.git' | grep -v README | grep -v LICENSE
	else
		echo $P/$1
	fi
	shift
done
