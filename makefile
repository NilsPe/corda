#MAKEFLAGS = -s

bld = build
src = src
classpath = classpath

arch = $(shell uname -m)
ifeq ($(arch),i586)
	arch = i386
endif
ifeq ($(arch),i686)
	arch = i386
endif

cxx = g++
cc = gcc
vg = nice valgrind --leak-check=full --num-callers=32 --db-attach=yes \
	--freelist-vol=100000000
javac = javac

warnings = -Wall -Wextra -Werror -Wold-style-cast -Wunused-parameter \
	-Winit-self -Wconversion

slow = -O0 -g3
fast = -Os -DNDEBUG

#thread-cflags = -DNO_THREADS
thread-cflags = -pthread
thread-lflags = -lpthread

cflags = $(warnings) -fPIC -fno-rtti -fno-exceptions -fvisibility=hidden \
	-I$(src) -I$(bld) $(thread-cflags)
lflags = $(thread-lflags) -ldl
test-cflags = -DDEBUG_MEMORY
stress-cflags = -DDEBUG_MEMORY -DDEBUG_MEMORY_MAJOR

cpp-objects = $(foreach x,$(1),$(patsubst $(2)/%.cpp,$(bld)/%.o,$(x)))
assembly-objects = $(foreach x,$(1),$(patsubst $(2)/%.S,$(bld)/%.o,$(x)))

stdcpp-sources = $(src)/stdc++.cpp
stdcpp-objects = $(call cpp-objects,$(stdcpp-sources),$(src))
stdcpp-cflags = $(fast) $(cflags)

jni-sources = $(classpath)/java/lang/System.cpp
jni-objects = $(call cpp-objects,$(jni-sources),$(classpath))
jni-cflags = -I/usr/lib/jvm/java-6-sun-1.6.0.00/include \
	-I/usr/lib/jvm/java-6-sun-1.6.0.00/include/linux \
	$(cflags)
jni-library = $(bld)/libnatives.so

generated-code = \
	$(bld)/type-enums.cpp \
	$(bld)/type-declarations.cpp \
	$(bld)/type-constructors.cpp \
	$(bld)/type-initializations.cpp \
	$(bld)/type-java-initializations.cpp
interpreter-depends = \
	$(generated-code) \
	$(src)/common.h \
	$(src)/system.h \
	$(src)/heap.h \
	$(src)/class-finder.h \
	$(src)/stream.h \
	$(src)/constants.h \
	$(src)/vm.h
interpreter-sources = \
	$(src)/vm.cpp \
	$(src)/heap.cpp \
	$(src)/main.cpp

ifeq ($(arch),i386)
	interpreter-assembly-sources = $(src)/cdecl.S
endif
ifeq ($(arch),x86_64)
	interpreter-assembly-sources = $(src)/amd64.S
endif

interpreter-cpp-objects = \
	$(call cpp-objects,$(interpreter-sources),$(src))
interpreter-assembly-objects = \
	$(call assembly-objects,$(interpreter-assembly-sources),$(src))
interpreter-objects = \
	$(interpreter-cpp-objects) \
	$(interpreter-assembly-objects)
interpreter-cflags = $(slow) $(cflags)

generator-headers = \
	$(src)/input.h \
	$(src)/output.h
generator-sources = \
	$(src)/type-generator.cpp
generator-objects = $(call cpp-objects,$(generator-sources),$(src))
generator-executable = $(bld)/generator
generator-cflags = $(slow) $(cflags)

executable = $(bld)/vm

test-objects = $(patsubst $(bld)/%,$(bld)/test-%,$(interpreter-objects))
test-executable = $(bld)/test-vm

stress-objects = $(patsubst $(bld)/%,$(bld)/stress-%,$(interpreter-objects))
stress-executable = $(bld)/stress-vm

fast-objects = $(patsubst $(bld)/%,$(bld)/fast-%,$(interpreter-objects))
fast-executable = $(bld)/fast-vm
fast-cflags = $(fast) $(cflags)

input = $(bld)/classes/Hello.class
input-depends = \
	$(bld)/classes/java/lang/System.class \
	$(jni-library)

gen-run-arg = $(shell echo $(1) | sed -e 's:$(bld)/classes/\(.*\)\.class:\1:')
args = -cp $(bld)/classes -hs 67108864 $(call gen-run-arg,$(input))

.PHONY: build
build: $(executable)

$(input): $(input-depends)

.PHONY: run
run: $(executable) $(input)
	LD_LIBRARY_PATH=$(bld) $(<) $(args)

.PHONY: debug
debug: $(executable) $(input)
	LD_LIBRARY_PATH=$(bld) gdb --args $(<) $(args)

.PHONY: fast
fast: $(fast-executable)
	ls -lh $(<)

.PHONY: vg
vg: $(executable) $(input)
	LD_LIBRARY_PATH=$(bld) $(vg) $(<) $(args)

.PHONY: test
test: $(test-executable) $(input)
	LD_LIBRARY_PATH=$(bld) $(vg) $(<) $(args)

.PHONY: stress
stress: $(stress-executable) $(input)
	LD_LIBRARY_PATH=$(bld) $(vg) $(<) $(args)

.PHONY: run-all
run-all: $(executable)
	set -e; for x in $(all-input); do echo "$$x:"; $(<) $$x; echo; done

.PHONY: vg-all
vg-all: $(executable)
	set -e; for x in $(all-input); do echo "$$x:"; $(vg) -q $(<) $$x; done

.PHONY: test-all
test-all: $(test-executable)
	set -e; for x in $(all-input); do echo "$$x:"; $(vg) -q $(<) $$x; done

.PHONY: stress-all
stress-all: $(stress-executable)
	set -e; for x in $(all-input); do echo "$$x:"; $(vg) -q $(<) $$x; done

.PHONY: clean
clean:
	@echo "removing $(bld)"
	rm -rf $(bld)

gen-arg = $(shell echo $(1) | sed -e 's:$(bld)/type-\(.*\)\.cpp:\1:')
$(generated-code): %.cpp: $(src)/types.def $(generator-executable)
	@echo "generating $(@)"
	$(generator-executable) $(call gen-arg,$(@)) < $(<) > $(@)

$(bld)/type-generator.o: \
	$(generator-headers)

$(bld)/classes/%.class: $(classpath)/%.java
	@echo "compiling $(@)"
	@mkdir -p $(dir $(@))
	$(javac) -bootclasspath $(classpath) -classpath $(classpath) \
		-d $(bld)/classes $(<)

$(stdcpp-objects): $(bld)/%.o: $(src)/%.cpp
	@echo "compiling $(@)"
	@mkdir -p $(dir $(@))
	$(cxx) $(stdcpp-cflags) -c $(<) -o $(@)

$(interpreter-cpp-objects): $(bld)/%.o: $(src)/%.cpp $(interpreter-depends)
	@echo "compiling $(@)"
	@mkdir -p $(dir $(@))
	$(cxx) $(interpreter-cflags) -c $(<) -o $(@)

$(interpreter-assembly-objects): $(bld)/%.o: $(src)/%.S
	@echo "compiling $(@)"
	@mkdir -p $(dir $(@))
	$(cxx) $(interpreter-cflags) -c $(<) -o $(@)

$(test-objects): $(bld)/test-%.o: $(src)/%.cpp $(interpreter-depends)
	@echo "compiling $(@)"
	@mkdir -p $(dir $(@))
	$(cxx) $(interpreter-cflags) $(test-cflags) -c $(<) -o $(@)

$(stress-objects): $(bld)/stress-%.o: $(src)/%.cpp $(interpreter-depends)
	@echo "compiling $(@)"
	@mkdir -p $(dir $(@))
	$(cxx) $(interpreter-cflags) $(stress-cflags) -c $(<) -o $(@)

$(generator-objects): $(bld)/%.o: $(src)/%.cpp
	@echo "compiling $(@)"
	@mkdir -p $(dir $(@))
	$(cxx) $(generator-cflags) -c $(<) -o $(@)

$(fast-objects): $(bld)/fast-%.o: $(src)/%.cpp $(interpreter-depends)
	@echo "compiling $(@)"
	@mkdir -p $(dir $(@))
	$(cxx) $(fast-cflags) -c $(<) -o $(@)

$(jni-objects): $(bld)/%.o: $(classpath)/%.cpp
	@echo "compiling $(@)"
	@mkdir -p $(dir $(@))
	$(cxx) $(jni-cflags) -c $(<) -o $(@)	

$(jni-library): $(jni-objects)
	@echo "linking $(@)"
	$(cc) $(lflags) -shared $(^) -o $(@)

$(executable): $(interpreter-objects) $(stdcpp-objects)
	@echo "linking $(@)"
	$(cc) $(lflags) $(^) -o $(@)

$(test-executable): $(test-objects) $(stdcpp-objects)
	@echo "linking $(@)"
	$(cc) $(lflags) $(^) -o $(@)

$(stress-executable): $(stress-objects) $(stdcpp-objects)
	@echo "linking $(@)"
	$(cc) $(lflags) $(^) -o $(@)

$(fast-executable): $(fast-objects) $(stdcpp-objects)
	@echo "linking $(@)"
	$(cc) $(lflags) $(^) -o $(@)
	strip --strip-all $(@)

.PHONY: generator
generator: $(generator-executable)

.PHONY: run-generator
run-generator: $(generator-executable)
	$(<) < $(src)/types.def

.PHONY: vg-generator
vg-generator: $(generator-executable)
	$(vg) $(<) < $(src)/types.def

$(generator-executable): $(generator-objects) $(stdcpp-objects)
	@echo "linking $(@)"
	$(cc) $(lflags) $(^) -o $(@)
