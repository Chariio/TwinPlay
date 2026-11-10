NECDSP necdsp;
}

#include "dscore/SnesTrace.hpp"

namespace dscore {
  void dsp1Reset();
  void dsp1Write(uint8_t data);
  uint8_t dsp1Read();
  uint8_t dsp1Status();
}

namespace ares::SuperFamicom {
#include "memory.cpp"
#include "debugger.cpp"
#include "serialization.cpp"

auto NECDSP::load(Node::Object parent) -> void {
  node = parent->append<Node::Object>("NEC");

  debugger.load(node);
}

auto NECDSP::unload() -> void {
  debugger = {};
  node = {};

  std::erase(cpu.coprocessors, this);
  Thread::destroy();
}

auto NECDSP::main() -> void {
  // Empty firmware used to exec() a 0-filled program on every DSP clock. Skip that.
  // The thread still yields once so the CPU keeps the same schedule. No picture scan.
  if(hle) {
    Thread::step(1);
    Thread::synchronize(cpu);
    return;
  }
  debugger.instruction();
  exec();

  Thread::step(1);
  Thread::synchronize(cpu);
}

auto NECDSP::power() -> void {
  uPD96050::power();
  hle = true;
  for(u32 n : range(16)) if(programROM[n]) { hle = false; break; }
  if(hle) dscore::dsp1Reset();
  Thread::create(Frequency, std::bind_front(&NECDSP::main, this));
  cpu.coprocessors.push_back(this);
}
