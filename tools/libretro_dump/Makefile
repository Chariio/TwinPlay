# Headless libretro frontend. The core .dylib is built outside this repo.
CXX ?= c++
CXXFLAGS ?= -std=c++20 -O2 -Wall -Wextra -Wno-unused-parameter
INCLUDES := -I../../Core/include

libretro_dump: main.cpp
	$(CXX) $(CXXFLAGS) $(INCLUDES) -o $@ main.cpp -ldl

clean:
	rm -f libretro_dump

.PHONY: clean
