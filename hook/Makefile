CXX = clang++
CXXFLAGS = -std=c++20 -O2 -Wall -Wextra -Werror

BUILD = .build
SRC = src/main.cpp
LIB_SRC =

.PHONY: all test clean

all: $(BUILD)/peekaboo-hook

$(BUILD)/peekaboo-hook: $(SRC)
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -o $@ $(SRC)

$(BUILD)/unit: test/unit.cpp $(LIB_SRC)
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -o $@ test/unit.cpp $(LIB_SRC)

test: $(BUILD)/unit $(BUILD)/peekaboo-hook
	$(BUILD)/unit
	python3 test/integration.py $(BUILD)/peekaboo-hook

clean:
	rm -rf $(BUILD)
