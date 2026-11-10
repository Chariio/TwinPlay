# Host build of the core for unit tests (Linux/macOS). The iOS app compiles
# the same sources through Xcode.
CXX ?= clang++
CC ?= clang
CXXFLAGS ?= -std=c++20 -O2 -g -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-enum-enum-conversion -Iinclude
ARES := third_party/ares
ARES_INC := -I$(ARES) -I$(ARES)/ares -I$(ARES)/nall -I$(ARES)/thirdparty/ymfm/src -I$(ARES)/no-jit
ARES_FLAGS := -std=c++20 -O2 -g -DNDEBUG -Wno-deprecated -Wno-switch -Wno-unused -Wno-sign-compare -Wno-reorder -Wno-parentheses -Wno-misleading-indentation -Wno-deprecated-enum-enum-conversion -fno-strict-aliasing $(ARES_INC)
SRC := $(wildcard src/*.cpp)
ARES_SRC := \
  $(ARES)/nall/nall/nall.cpp \
  $(ARES)/ares/component/processor/mos6502/mos6502.cpp \
  $(ARES)/ares/component/processor/wdc65816/wdc65816.cpp \
  $(ARES)/ares/component/processor/spc700/spc700.cpp \
  $(ARES)/ares/component/processor/arm7tdmi/arm7tdmi.cpp \
  $(ARES)/ares/component/processor/gsu/gsu.cpp \
  $(ARES)/ares/component/processor/hg51b/hg51b.cpp \
  $(ARES)/ares/component/processor/upd96050/upd96050.cpp \
  $(ARES)/ares/component/audio/ym2149/ym2149.cpp \
  $(ARES)/ares/component/audio/ym2413/ym2413.cpp \
  $(ARES)/ares/component/eeprom/m24c/m24c.cpp \
  $(ARES)/ares/component/flash/sst39sf0x0/sst39sf0x0.cpp \
  $(ARES)/ares/component/arcade/dip-switches.cpp \
  $(wildcard $(ARES)/thirdparty/ymfm/src/*.cpp)

OBJDIR := build/objs
CORE_OBJS := $(patsubst src/%.cpp,$(OBJDIR)/%.o,$(SRC))
ARES_OBJS := $(patsubst %.cpp,$(OBJDIR)/%.o,$(notdir $(ARES_SRC)))
LIBCO := $(OBJDIR)/libco.o
LDFLAGS := -lpthread -ldl
ifeq ($(shell uname -s),Darwin)
  # nall::Path calls CFBundle* / CFURL* / CFRelease.
  LDFLAGS += -framework CoreFoundation
endif

test: build/core_tests build/nes_snes_tests build/n64_3ds_tests
	./build/core_tests
	./build/nes_snes_tests
	./build/n64_3ds_tests

# The binary lives in build/. `make snes_race_harness` builds it.
snes_race_harness: build/snes_race_harness

build/core_tests: $(CORE_OBJS) $(ARES_OBJS) $(LIBCO) $(OBJDIR)/core_tests.o $(OBJDIR)/n64_stub.o $(OBJDIR)/n3ds_stub.o
	$(CXX) -g -o $@ $(CORE_OBJS) $(ARES_OBJS) $(LIBCO) $(OBJDIR)/core_tests.o $(OBJDIR)/n64_stub.o $(OBJDIR)/n3ds_stub.o $(LDFLAGS)

build/nes_snes_tests: $(CORE_OBJS) $(ARES_OBJS) $(LIBCO) $(OBJDIR)/nes_snes_tests.o $(OBJDIR)/n64_stub.o $(OBJDIR)/n3ds_stub.o
	$(CXX) -g -o $@ $(CORE_OBJS) $(ARES_OBJS) $(LIBCO) $(OBJDIR)/nes_snes_tests.o $(OBJDIR)/n64_stub.o $(OBJDIR)/n3ds_stub.o $(LDFLAGS)

build/n64_3ds_tests: $(CORE_OBJS) $(ARES_OBJS) $(LIBCO) $(OBJDIR)/n64_3ds_tests.o $(OBJDIR)/n64_stub.o $(OBJDIR)/n3ds_stub.o
	$(CXX) -g -o $@ $(CORE_OBJS) $(ARES_OBJS) $(LIBCO) $(OBJDIR)/n64_3ds_tests.o $(OBJDIR)/n64_stub.o $(OBJDIR)/n3ds_stub.o $(LDFLAGS)

build/snes_race_harness: $(CORE_OBJS) $(ARES_OBJS) $(LIBCO) $(OBJDIR)/snes_race_harness.o $(OBJDIR)/n64_stub.o $(OBJDIR)/n3ds_stub.o
	$(CXX) -g -o $@ $(CORE_OBJS) $(ARES_OBJS) $(LIBCO) $(OBJDIR)/snes_race_harness.o $(OBJDIR)/n64_stub.o $(OBJDIR)/n3ds_stub.o $(LDFLAGS)

$(OBJDIR)/core_tests.o: tests/core_tests.cpp
	@mkdir -p $(OBJDIR)
	$(CXX) $(CXXFLAGS) $(ARES_INC) -c $< -o $@

$(OBJDIR)/nes_snes_tests.o: tests/nes_snes_tests.cpp
	@mkdir -p $(OBJDIR)
	$(CXX) $(CXXFLAGS) $(ARES_INC) -c $< -o $@

$(OBJDIR)/n64_3ds_tests.o: tests/n64_3ds_tests.cpp
	@mkdir -p $(OBJDIR)
	$(CXX) $(CXXFLAGS) $(ARES_INC) -c $< -o $@

$(OBJDIR)/n64_stub.o: n64/twinplay_n64_stub.c
	@mkdir -p $(OBJDIR)
	$(CC) -std=c11 -O2 -g -c $< -o $@

$(OBJDIR)/n3ds_stub.o: n3ds/twinplay_3ds_stub.c
	@mkdir -p $(OBJDIR)
	$(CC) -std=c11 -O2 -g -c $< -o $@

$(OBJDIR)/snes_race_harness.o: tests/snes_race_harness.cpp
	@mkdir -p $(OBJDIR)
	$(CXX) $(CXXFLAGS) $(ARES_INC) -c $< -o $@

# sfc sources are #included by src/AresBuild.cpp. Make must rebuild that object
# when the included CPU or PPU files change.
$(OBJDIR)/AresBuild.o: \
	$(wildcard $(ARES)/ares/sfc/cpu/*.*) \
	$(wildcard $(ARES)/ares/sfc/ppu-performance/*.*) \
	$(wildcard $(ARES)/ares/sfc/coprocessor/necdsp/*.*)

$(OBJDIR)/%.o: src/%.cpp
	@mkdir -p $(OBJDIR)
	$(CXX) $(ARES_FLAGS) -Iinclude -c $< -o $@

$(OBJDIR)/libco.o: $(ARES)/libco/libco.c
	@mkdir -p $(OBJDIR)
	$(CC) -std=c11 -O2 -g -c $< -o $@

# Third-party translation units. vpath finds them; the recipe uses the first match.
vpath %.cpp $(ARES)/nall/nall $(ARES)/ares/component/processor/mos6502 $(ARES)/ares/component/processor/wdc65816 $(ARES)/ares/component/processor/spc700 $(ARES)/ares/component/processor/arm7tdmi $(ARES)/ares/component/processor/gsu $(ARES)/ares/component/processor/hg51b $(ARES)/ares/component/processor/upd96050 $(ARES)/ares/component/audio/ym2149 $(ARES)/ares/component/audio/ym2413 $(ARES)/ares/component/eeprom/m24c $(ARES)/ares/component/flash/sst39sf0x0 $(ARES)/ares/component/arcade $(ARES)/thirdparty/ymfm/src

$(OBJDIR)/%.o: %.cpp
	@mkdir -p $(OBJDIR)
	$(CXX) $(ARES_FLAGS) -c $< -o $@

clean:
	rm -rf build
.PHONY: test clean snes_race_harness
