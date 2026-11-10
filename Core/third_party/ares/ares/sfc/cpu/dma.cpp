inline auto CPU::dmaEnable() -> bool {
  for(auto& channel : channels) if(channel.dmaEnable) return true;
  return false;
}

inline auto CPU::hdmaEnable() -> bool {
  for(auto& channel : channels) if(channel.hdmaEnable) return true;
  return false;
}

inline auto CPU::hdmaActive() -> bool {
  for(auto& channel : channels) if(channel.hdmaActive()) return true;
  return false;
}

auto CPU::dmaRun() -> void {
  counter.dma += 8;
  step(8);
  dmaEdge();
  for(auto& channel : channels) channel.dmaRun();
  status.irqLock = true;
}

auto CPU::hdmaReset() -> void {
  for(auto& channel : channels) channel.hdmaReset();
}

auto CPU::hdmaSetup() -> void {
  counter.dma += 8;
  step(8);
  if(dscore::snesTraceEnabled) {
    int v = (int)vcounter(), dot = (int)hdot();
    for(auto& channel : channels) {
      dscore::snesTraceHdmaSetup((int)channel.id, (int)(bool)channel.hdmaEnable, (int)channel.transferMode,
        (int)(bool)channel.indirect, (int)channel.targetAddress,
        (uint32_t)channel.sourceBank << 16 | (uint32_t)channel.sourceAddress, v, dot);
    }
  }
  for(auto& channel : channels) channel.hdmaSetup();
  status.irqLock = true;
}

auto CPU::hdmaRun() -> void {
  counter.dma += 8;
  step(8);
  for(auto& channel : channels) channel.hdmaTransfer();
  for(auto& channel : channels) channel.hdmaAdvance();
  status.irqLock = true;
}

//

inline auto CPU::Channel::step(u32 clocks) -> void {
  cpu.counter.dma += clocks;
  cpu.step(clocks);
}

inline auto CPU::Channel::edge() -> void {
  cpu.dmaEdge();
}

inline auto CPU::Channel::validA(n24 address) -> bool {
  //A-bus cannot access the B-bus or CPU I/O registers
  if((address & 0x40ff00) == 0x2100) return false;  //00-3f,80-bf:2100-21ff
  if((address & 0x40fe00) == 0x4000) return false;  //00-3f,80-bf:4000-41ff
  if((address & 0x40ffe0) == 0x4200) return false;  //00-3f,80-bf:4200-421f
  if((address & 0x40ff80) == 0x4300) return false;  //00-3f,80-bf:4300-437f
  return true;
}

inline auto CPU::Channel::dspWindow(n24 address) -> bool {
  u32 bank = address >> 16;
  u32 offs = address & 0xffff;
  bool hi = bank <= 0x1f || (bank >= 0x80 && bank <= 0x9f);
  if(hi && offs >= 0x6000 && offs <= 0x7fff) return true;                 // 1K1X: $6000 data, $7000 status
  bool lo = (bank >= 0x20 && bank <= 0x3f) || (bank >= 0xa0 && bank <= 0xbf);
  if(lo && offs >= 0x8000) return true;                                  // LoROM DSP window
  bool mid = (bank >= 0x60 && bank <= 0x6f) || (bank >= 0xe0 && bank <= 0xef);
  if(mid && offs <= 0x7fff) return true;
  return false;
}

inline auto CPU::Channel::readA(n24 address) -> n8 {
  step(4);
  cpu.r.mdr = validA(address) ? bus.read(address, cpu.r.mdr) : (n8)0x00;
  step(4);
  if(dscore::snesTraceEnabled && cpu.traceDma && dspWindow(address))
    dscore::snesTraceDmaDsp((int)id, 0, address, cpu.r.mdr, (int)cpu.vcounter(), (int)cpu.hdot());
  if(dscore::snesTraceEnabled && cpu.traceHdma)
    dscore::snesTraceHdmaSource((int)id, address, (int)(address >> 16), (int)cpu.vcounter(), (int)cpu.hdot(), cpu.r.mdr);
  return cpu.r.mdr;
}

inline auto CPU::Channel::readB(n8 address, bool valid) -> n8 {
  step(4);
  cpu.r.mdr = valid ? bus.read(0x2100 | address, cpu.r.mdr) : (n8)0x00;
  step(4);
  return cpu.r.mdr;
}

inline auto CPU::Channel::writeA(n24 address, n8 data) -> void {
  if(validA(address)) {
    bus.write(address, data);
    if(dscore::snesTraceEnabled && cpu.traceDma && dspWindow(address))
      dscore::snesTraceDmaDsp((int)id, 1, address, data, (int)cpu.vcounter(), (int)cpu.hdot());
    if(dscore::snesTraceEnabled) {
      bool mirror = (address & 0x40e000) == 0;
      bool full = (address & 0xfe0000) == 0x7e0000;
      if(mirror || full) {
        u32 offset = mirror ? (address & 0x1fff) : (address & 0x1ffff);
        dscore::snesTraceWram(1, id, offset, data, (int)cpu.vcounter(), (int)cpu.hdot());
      }
    }
    if(dscore::snesWatchEnabled && (address & 0xfe0000) == 0x7e0000) {
      u32 offset = (u32)address & 0x1ffff;
      if(offset >= 0x3c00 && offset <= 0xffff)
        dscore::snesWatchWram(cpu.watchViaHdma ? 2 : 1, (int)id, 0, offset, (u8)data, (int)cpu.vcounter());
    }
  }
}

inline auto CPU::Channel::writeB(n8 address, n8 data, bool valid) -> void {
  if(valid) {
    if(dscore::snesTraceEnabled && cpu.traceHdma)
      dscore::snesTraceHdmaByte((int)cpu.traceHdmaChannel, 0x2100 | address, data, (int)cpu.vcounter(), (int)cpu.hdot());
    bus.write(0x2100 | address, data);
  }
}

inline auto CPU::Channel::transfer(n24 addressA, n2 index) -> void {
  n8 addressB = targetAddress;
  switch(transferMode) {
  case 1: case 5: addressB += index.bit(0); break;
  case 3: case 7: addressB += index.bit(1); break;
  case 4: addressB += index; break;
  }

  //transfers from WRAM to WRAM are invalid
  bool valid = addressB != 0x80 || ((addressA & 0xfe0000) != 0x7e0000 && (addressA & 0x40e000) != 0x0000);

  cpu.r.mar = addressA;
  if(direction == 0) {
    auto data = readA(addressA);
    writeB(addressB, data, valid);
    if(valid) cpu.debugger.dma(id, addressA, addressB, data);
  } else {
    auto data = readB(addressB, valid);
    writeA(addressA, data);
    if(valid) cpu.debugger.dma(id, addressA, addressB, data);
  }
}

inline auto CPU::Channel::dmaRun() -> void {
  if(!dmaEnable) return;

  step(8);
  edge();

  n2 index = 0;
  int savedWriter = cpu.watchWriter;
  bool savedHdma = cpu.watchViaHdma;
  cpu.watchWriter = (int)id;
  cpu.watchViaHdma = false;
  if(dscore::snesTraceEnabled) {
    cpu.traceDma = true;
    cpu.traceDmaChannel = id;
  }
  do {
    transfer(sourceBank << 16 | sourceAddress, index++);
    if(!fixedTransfer) !reverseTransfer ? sourceAddress++ : sourceAddress--;
    edge();
  } while(dmaEnable && --transferSize);

  cpu.traceDma = false;
  cpu.watchWriter = savedWriter;
  cpu.watchViaHdma = savedHdma;
  dmaEnable = false;
}

inline auto CPU::Channel::hdmaActive() -> bool {
  return hdmaEnable && !hdmaCompleted;
}

inline auto CPU::Channel::hdmaFinished() -> bool {
  auto channel = next;
  while(channel) {
    if(channel->hdmaActive()) return false;
    channel = channel->next;
  }
  return true;
}

inline auto CPU::Channel::hdmaReset() -> void {
  hdmaCompleted = false;
  hdmaDoTransfer = false;
}

inline auto CPU::Channel::hdmaSetup() -> void {
  hdmaDoTransfer = true;  //note: needs hardware verification
  if(!hdmaEnable) return;

  dmaEnable = false;  //HDMA will stop active DMA mid-transfer
  hdmaAddress = sourceAddress;
  lineCounter = 0;
  hdmaReload();
}

inline auto CPU::Channel::hdmaReload() -> void {
  auto data = readA(cpu.r.mar = sourceBank << 16 | hdmaAddress);

  if((n7)lineCounter == 0) {
    lineCounter = data;
    hdmaAddress++;

    hdmaCompleted = lineCounter == 0;
    hdmaDoTransfer = !hdmaCompleted;

    if(indirect) {
      data = readA(cpu.r.mar = sourceBank << 16 | hdmaAddress++);
      indirectAddress = data << 8 | 0x00;  //todo: should 0x00 be indirectAddress >> 8 ?
      if(hdmaCompleted && hdmaFinished()) return;

      data = readA(cpu.r.mar = sourceBank << 16 | hdmaAddress++);
      indirectAddress = data << 8 | indirectAddress >> 8;
    }
  }
}

inline auto CPU::Channel::hdmaTransfer() -> void {
  if(!hdmaActive()) return;
  dmaEnable = false;  //HDMA will stop active DMA mid-transfer
  if(!hdmaDoTransfer) {
    if(dscore::snesTraceEnabled)
      dscore::snesTraceHdmaHold((int)id, (int)cpu.vcounter(), (int)cpu.hdot());
    return;
  }

  static constexpr u32 lengths[8] = {1, 2, 2, 4, 4, 4, 2, 4};
  int savedWriter = cpu.watchWriter;
  bool savedHdma = cpu.watchViaHdma;
  cpu.watchWriter = (int)id;
  cpu.watchViaHdma = true;
  if(dscore::snesTraceEnabled) {
    cpu.traceHdma = true;
    cpu.traceHdmaChannel = id;
  }
  for(n2 index : range(lengths[transferMode])) {
    n24 address = !indirect ? sourceBank << 16 | hdmaAddress++ : indirectBank << 16 | indirectAddress++;
    transfer(address, index);
  }
  cpu.traceHdma = false;
  cpu.watchWriter = savedWriter;
  cpu.watchViaHdma = savedHdma;
}

inline auto CPU::Channel::hdmaAdvance() -> void {
  if(!hdmaActive()) return;
  lineCounter--;
  hdmaDoTransfer = lineCounter.bit(7);
  hdmaReload();
}
