auto CPU::idle() -> void {
  status.clockCount = 6;
  dmaEdge();
  step(6);
  aluEdge();
}

auto CPU::read(n24 address) -> n8 {
  status.clockCount = wait(address);
  dmaEdge();
  r.mar = address;
  step(status.clockCount - 4);
  auto data = bus.read(address, r.mdr);
  step(4);
  aluEdge();
  //$00-3f,80-bf:4000-43ff reads are internal to CPU, and do not update the MDR
  if((address & 0x40fc00) != 0x4000) r.mdr = data;
  return data;
}

auto CPU::write(n24 address, n8 data) -> void {
  aluEdge();
  status.clockCount = wait(address);
  dmaEdge();
  r.mar = address;
  step(status.clockCount);
  // Commit the store before any log. A recorder must not be able to skip the write.
  bus.write(address, r.mdr = data);
  // $00-3f,80-bf:2100-21ff. HDMA writes the same registers through writeB, not here.
  if(dscore::snesTraceEnabled && (address & 0x40ff00) == 0x2100)
    dscore::snesTraceCpuPpu(address, data, (int)vcounter(), (int)hdot());
  if(dscore::snesTraceEnabled) {
    bool mirror = (address & 0x40e000) == 0;
    bool full = (address & 0xfe0000) == 0x7e0000;
    if(mirror || full) {
      u32 offset = mirror ? (address & 0x1fff) : (address & 0x1ffff);
      dscore::snesTraceWram(0, (u32)r.pc.d, offset, data, (int)vcounter(), (int)hdot());
    }
  }
  // $7E3C00-$7EFFFF only. $2180 lands in writeCPU, not here.
  if(dscore::snesWatchEnabled && (address & 0xfe0000) == 0x7e0000) {
    u32 offset = (u32)address & 0x1ffff;
    if(offset >= 0x3c00 && offset <= 0xffff)
      dscore::snesWatchWram(0, -1, (u32)r.pc.d, offset, (u8)data, (int)vcounter());
  }
}

alwaysinline auto CPU::wait(n24 address) const -> u32 {
  //00-3f,80-bf:8000-ffff; 40-7f,c0-ff:0000-ffff
  if(address & 0x408000) return address & 0x800000 ? io.romSpeed : 8;

  //00-3f,80-bf:0000-1fff,6000-7fff
  if(address + 0x6000 & 0x4000) return 8;

  //00-3f,80-bf:2000-3fff,4200-5fff
  if(address - 0x4000 & 0x7e00) return 6;

  //00-3f,80-bf:4000-41ff
  return 12;
}

auto CPU::readDisassembler(n24 address) -> n8 {
  return bus.read(address, r.mdr);
}
