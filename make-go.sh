#!/bin/sh

PWD=`pwd`
PROJECT=`basename $PWD`

VERBOSITY=0
VERBOSITYFLAGS=""
while test "$1" = "-v"; do
	VERBOSITY=$((VERBOSITY+1))
	VERBOSITYFLAGS="$VERBOSITYFLAGS -v"
	shift
done

now()
{
	date +%s%N
}

run()
{
	if test $VERBOSITY -gt 1; then echo "$@"; fi
	"$@" || exit 1
}

printv()
{
	if test $VERBOSITY -gt 0; then echo "$@"; fi
}

ISPCFILES="lib"$PROJECT"ispc.[ah] lib"$PROJECT"ispc.so"
buildISPC()
{
	FILES=`ls *.ispc 2>/dev/null`
	if test "$FILES" != ""; then
		CGO_ENABLED=1; export CGO_ENABLED
		rm -f $ISPCFILES

		for file in $FILES; do
			BASE=`echo $file | cut -d '.' -f 1`
			run ispc $@ --target=host -o $BASE.o -h $BASE.h --pic $file
		done

		printv cat *.h
		cat *.h >lib"$PROJECT"ispc.h
		run rm -f `ls *.h | grep -v lib"$PROJECT"ispc`

		run ar rc lib"$PROJECT"ispc.a *.o
		run ld -o lib"$PROJECT"ispc.so -shared *.o
		run rm -f *.o
	fi
}

# NOTE(anton2920): don't like Google spying on me.
GOPROXY=direct; export GOPROXY
GOSUMDB=off; export GOSUMDB

# NOTE(anton2920): disable Go 1.11+ package management.
GO111MODULE=off; export GO111MODULE
GOPATH=`go env GOPATH`:`pwd`; export GOPATH

CGO_ENABLED=0; export CGO_ENABLED

test "$GO14" = "true" && . go14-env

STARTTIME=`now`

TARGET=$1
shift

GPPTARGET=`grep -n gpp *.go? 2>/dev/null | cut -d ':' -f 1 | uniq | grep -v gpp`
test "$GPPTARGET" != "" && run gpp -r

case $TARGET in
	'' | debug)
		CGO_ENABLED=1; export CGO_ENABLED
		run buildISPC -O0 -g
		if test "$GO14" = "true"; then
			run go build $VERBOSITYFLAGS -o $PROJECT -gcflags="-N -l" -tags gofadebug $@
		else
			grep 'import "C"' *.go >/dev/null && RACE= || RACE=-race
			run go build $VERBOSITYFLAGS -o $PROJECT $RACE -pgo off -gcflags="all=-N -l" -tags gofadebug $@
		fi
		;;
	allocs | allocations)
		printv go build $VERBOSITYFLAGS -o /dev/null -gcflags="all=-m -m"
		if test "$GO14" = "true"; then
			go build $VERBOSITYFLAGS -o /dev/null -gcflags="-m -m" 2>&1 | sort | uniq | grep "moved to heap" >$PROJECT.esc
		else
			go build $VERBOSITYFLAGS -o /dev/null -gcflags="all=-m -m" 2>&1 | sort | uniq | grep "moved to heap" >$PROJECT.esc
		fi
		;;
	allocs-plus | allocations-plus)
		printv go build $VERBOSITYFLAGS -o /dev/null -gcflags="all=-m -m"
		if test "$GO14" = "true"; then
			go build $VERBOSITYFLAGS -o /dev/null -gcflags="-m" 2>&1 | sort | uniq | grep "escapes to heap" >$PROJECT.esc
		else
			go build $VERBOSITYFLAGS -o /dev/null -gcflags="all=-m -m" 2>&1 | sort | uniq | grep "escapes to heap" | grep " in " >$PROJECT.esc
		fi
		;;
	clean)
		run rm -f *_gpp.go $PROJECT $PROJECT.[sS] $PROJECT.esc $PROJECT.test $PROJECT.test.esc c.out cpu.pprof mem.pprof $ISPCFILES
		run go clean -cache -modcache -testcache
		run rm -rf `go env GOCACHE`
		run rm -rf /tmp/cover*
		;;
	check)
		run $0 $VERBOSITYFLAGS test-race-cover
		run ./$PROJECT.test $@
		;;
	check-bench)
		run $0 $VERBOSITYFLAGS test
		run ./$PROJECT.test -test.run=^Benchmark -test.benchmem -test.bench=. $@
		;;
	check-bench-cmp | check-bench-compare)
		run $0 check-bench -test.count=8 -test.bench=$1 | tee after

		git stash >/dev/null
		run $0 check-bench -test.count=8 -test.bench=$1 |tee before
		git stash pop >/dev/null

		OUTPUT=$PROJECT-diff.txt
		printv benchstat before after
		benchstat before after >$OUTPUT
		echo Results saved in $OUTPUT

		rm -f before after
		;;
	check-bench-cpu)
		run $0 $VERBOSITYFLAGS test

		OUTPUT=$PROJECT-cpu.pprof
		run ./$PROJECT.test -test.run=^Benchmark -test.benchmem -test.bench=. -test.cpuprofile=$OUTPUT $@
		echo Results saved in $OUTPUT
		;;
	check-bench-mem)
		run $0 $VERBOSITYFLAGS test

		OUTPUT=$PROJECT-mem.pprof
		run ./$PROJECT.test -test.run=^Benchmark -test.benchmem -test.bench=. -test.memprofile=$OUTPUT $@
		echo Results saved in $OUTPUT
		;;
	check-bench-tracing)
		run $0 $VERBOSITYFLAGS test-tracing
		run ./$PROJECT.test -test.run=^Benchmark -test.benchmem -test.bench=. $@
		;;
	check-cover)
		run $0 $VERBOSITYFLAGS test-race-cover
		run ./$PROJECT.test -test.coverprofile=c.out

		OUTPUT=/tmp/coverage.html
		run go tool cover -html=c.out -o $OUTPUT
		echo Results saved in $OUTPUT

		run rm -f c.out
		;;
	check-msan)
		run $0 $VERBOSITYFLAGS test-msan
		run ./$PROJECT.test
		;;
	disas | disasm | disassembly)
		printv go build $VERBOSITYFLAGS -o /dev/null -gcflags="all=-S"
		go build $VERBOSITYFLAGS -o /dev/null -gcflags="all=-S" >$PROJECT.S 2>&1
		;;
	esc | escape | escape-analysis)
		printv go build $VERBOSITYFLAGS -o /dev/null -gcflags="all=-m -m"
		go build $VERBOSITYFLAGS -o /dev/null -gcflags="all=-m -m" >$PROJECT.esc 2>&1
		;;
	fmt)
		which goimports >/dev/null && run goimports -l -w *.go || run gofmt -l -s -w *.go
		;;
	objdump)
		printv go tool objdump $@ $PROJECT
		go tool objdump $@ $PROJECT >$PROJECT.s
		;;
	pgo)
		run $0 $VERBOSITYFLAGS test

		printv ./$PROJECT.test -test.run=^Benchmark -test.benchmem -test.bench=. -test.count=8 -test.cpuprofile=$PROJECT-cpu.pprof
		./$PROJECT.test -test.run=^Benchmark -test.benchmem -test.bench=. -test.count=8 -test.cpuprofile=$PROJECT-cpu.pprof | tee before

		run go test $VERBOSITYFLAGS -c -o $PROJECT.test -pgo=$PROJECT-cpu.pprof -vet=off

		printv ./$PROJECT.test -test.run=^Benchmark -test.benchmem -test.bench=. -test.count=10 -test.cpuprofile=tmp.pprof
		./$PROJECT.test -test.run=^Benchmark -test.benchmem -test.bench=. -test.count=10 -test.cpuprofile=tmp.pprof | tee after

		OUTPUT=$PROJECT-diff.txt
		printv benchstat before after
		benchstat before after >$OUTPUT
		echo Results saved in $OUTPUT

		run rm before after tmp.pprof
		;;
	png)
		OUTPUT=/tmp/cpu.png
		run go tool pprof -png $PROJECT-cpu.pprof >$OUTPUT
		echo Results saved in $OUTPUT
		;;
	profiling)
		run go build $VERBOSITYFLAGS -o $PROJECT -ldflags="-X main.BuildMode=Profiling"
		;;
	release)
		run buildISPC -O3
		run go build $VERBOSITYFLAGS -o $PROJECT
		;;
	release-unsafe)
		run buildISPC -O3
		if test "$GO14" = "true"; then
			run go build $VERBOSITYFLAGS -o $PROJECT -gcflags="-B"
		else
			run go build $VERBOSITYFLAGS -o $PROJECT -gcflags="all=-B"
		fi
		;;
	run)
		run $0 $@
		./$PROJECT
		;;
	test)
		run buildISPC -O3
		run $0 $VERBOSITYFLAGS vet
		run go test $VERBOSITYFLAGS -c -o $PROJECT.test -vet=off
		;;
	test-msan)
		CGO_ENABLED=1; export CGO_ENABLED
		run buildISPC -O3
		run $0 $VERBOSITYFLAGS vet
		run go test $VERBOSITYFLAGS -c -o $PROJECT.test -vet=off -msan -gcflags="all=-N -l" -tags gofadebug
		;;
	test-race-cover)
		CGO_ENABLED=1; export CGO_ENABLED
		run buildISPC -O0 -g
		run $0 $VERBOSITYFLAGS vet
		run go test $VERBOSITYFLAGS -c -o $PROJECT.test -vet=off -race -cover -gcflags="all=-N -l" -tags gofadebug
		;;
	test-tracing)
		run buildISPC -O3
		run $0 $VERBOSITYFLAGS vet
		run go test $VERBOSITYFLAGS -c -o $PROJECT.test -vet=off -tags gofatrace
		;;
	tracing)
		run buildISPC -O3
		run go build $VERBOSITYFLAGS -o $PROJECT -tags gofatrace
		;;
	vet)
		if test ! "$GO14" = "true"; then
			# run go vet $VERBOSITYFLAGS -unsafeptr=false
			run go vet $VERBOSITYFLAGS
		fi
		;;
	*)
		printf "Target '%s' is not supported!\n" $TARGET >&2
		exit 1
		;;
esac

ENDTIME=`now`
ELAPSEDMS=`echo "scale=2; ($ENDTIME-$STARTTIME)/1000000" | bc`

echo Done $TARGET in "$ELAPSEDMS"ms
