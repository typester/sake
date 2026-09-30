# Compiles xgameruntime.dll. Fetching the compiler and libHttpClient is not this file's
# job: SakeKit pins its sources, and README.md has the commands for doing it by hand.

ifeq ($(origin CXX),default)
CXX = x86_64-w64-mingw32-clang++
endif

LIBHTTPCLIENT ?= $(error LIBHTTPCLIENT must name an unpacked libHttpClient tree)
OUT ?= ../target/xgameruntime

TASK = AsyncLib TaskQueue ThreadPool_win32 WaitTimer_win32
OWN = log main threading system networking user signin session

# libHttpClient is compiled by absolute path, and its __FILE__ would put that path, with the
# person's home in it, into the copy in every bottle.
CXXFLAGS = -std=c++20 -O2 -DNDEBUG -Isrc -I$(LIBHTTPCLIENT)/Include -I$(LIBHTTPCLIENT)/Source/Task \
           -ffile-prefix-map=$(LIBHTTPCLIENT)=libHttpClient
OBJS = $(TASK:%=$(OUT)/obj/libHttpClient/%.o) $(OWN:%=$(OUT)/obj/%.o)

$(OUT)/xgameruntime.dll: $(OBJS) xgameruntime.def
	$(CXX) -shared -static -o $@ $(OBJS) xgameruntime.def -lole32

$(OUT)/obj/libHttpClient/%.o: $(LIBHTTPCLIENT)/Source/Task/%.cpp src/pch.h
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) -w -c -o $@ $<

$(OUT)/obj/%.o: src/%.cpp src/runtime.h src/mailbox.h src/guids.h src/pch.h
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) -Wall -Wextra -Wno-unused-parameter -c -o $@ $<

clean:
	rm -rf $(OUT)

.PHONY: clean
