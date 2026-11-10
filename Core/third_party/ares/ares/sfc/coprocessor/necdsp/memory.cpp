auto NECDSP::read(n24 address, n8) -> n8 {
  cpu.synchronize(*this);
  if(hle) {
    // Bit 0 of the reduced address is the status port ($7xxx / $C000). The data
    // port is $6xxx / $8000. RQM stays set so the game is not spun on a blank ROM.
    n8 data = address.bit(0) ? dscore::dsp1Status() : dscore::dsp1Read();
    if(dscore::snesTraceEnabled) {
      int source = cpu.traceDma ? 1 : cpu.traceHdma ? 2 : 0;
      int channel = cpu.traceDma ? (int)cpu.traceDmaChannel : cpu.traceHdma ? (int)cpu.traceHdmaChannel : -1;
      dscore::snesTraceDspBus(0, address, data, (int)cpu.vcounter(), (int)cpu.hdot(), source, channel);
    }
    return data;
  }
  if(address.bit(0)) {
    return uPD96050::readSR();
  } else {
    return uPD96050::readDR();
  }
}

auto NECDSP::write(n24 address, n8 data) -> void {
  cpu.synchronize(*this);
  if(hle) {
    if(dscore::snesTraceEnabled) {
      int source = cpu.traceDma ? 1 : cpu.traceHdma ? 2 : 0;
      int channel = cpu.traceDma ? (int)cpu.traceDmaChannel : cpu.traceHdma ? (int)cpu.traceHdmaChannel : -1;
      dscore::snesTraceDspBus(1, address, data, (int)cpu.vcounter(), (int)cpu.hdot(), source, channel);
    }
    if(address.bit(0)) return;
    dscore::dsp1Write(data);
    return;
  }
  if(address.bit(0)) {
    return uPD96050::writeSR(data);
  } else {
    return uPD96050::writeDR(data);
  }
}

auto NECDSP::readRAM(n24 address, n8) -> n8 {
  cpu.synchronize(*this);
  return uPD96050::readDP(address);
}

auto NECDSP::writeRAM(n24 address, n8 data) -> void {
  cpu.synchronize(*this);
  return uPD96050::writeDP(address, data);
}
