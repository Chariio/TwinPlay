auto SuperFX::waitGate(bool rom) -> void {
  auto open = [&] { return rom ? (bool)regs.scmr.ron : (bool)regs.scmr.ran; };
  if(open() || scheduler.synchronizing()) return;
  // The CPU is the only writer of RON/RAN. Give it a short window, then continue.
  // Calling step() here is the hang: step() completes a ROM buffer by calling read(),
  // and read() would call step() again. Thread::step only advances the clock.
  u64 seen = cpu.clock();
  for(u32 n = 0; n < 32 && !open(); n++) {
    if(scheduler.synchronizing()) return;
    Thread::step(6);
    Thread::synchronize(cpu);
    if(cpu.clock() == seen) return;
    seen = cpu.clock();
  }
}

auto SuperFX::read(n24 address, n8 data) -> n8 {
  if((address & 0xc00000) == 0x000000) {  //$00-3f:0000-7fff,:8000-ffff
    waitGate(true);
    return rom.read((((address & 0x3f0000) >> 1) | (address & 0x7fff)) & romMask);
  }

  if((address & 0xe00000) == 0x400000) {  //$40-5f:0000-ffff
    waitGate(true);
    return rom.read(address & romMask);
  }

  if((address & 0xfe0000) == 0x700000) {  //$70-71:0000-ffff
    waitGate(false);
    return ram.read(address & ramMask);
  }

  return data;
}

auto SuperFX::write(n24 address, n8 data) -> void {
  if((address & 0xfe0000) == 0x700000) {  //$70-71:0000-ffff
    waitGate(false);
    return ram.write(address & ramMask, data);
  }
}

auto SuperFX::readOpcode(n16 address) -> n8 {
  n16 offset = address - regs.cbr;
  if(offset < 512) {
    if(cache.valid[offset >> 4] == false) {
      u32 dp = offset & 0xfff0;
      u32 sp = (regs.pbr << 16) + ((regs.cbr + dp) & 0xfff0);
      for(u32 n : range(16)) {
        step(regs.clsr ? 5 : 6);
        cache.buffer[dp++] = read(sp++);
      }
      cache.valid[offset >> 4] = true;
    } else {
      step(regs.clsr ? 1 : 2);
    }
    return cache.buffer[offset];
  }

  if(regs.pbr <= 0x5f) {
    //$00-5f:0000-ffff ROM
    syncROMBuffer();
    step(regs.clsr ? 5 : 6);
    return read(regs.pbr << 16 | address);
  } else {
    //$60-7f:0000-ffff RAM
    syncRAMBuffer();
    step(regs.clsr ? 5 : 6);
    return read(regs.pbr << 16 | address);
  }
}

inline auto SuperFX::peekpipe() -> n8 {
  n8 result = regs.pipeline;
  regs.pipeline = readOpcode(regs.r[15]);
  regs.r[15].modified = false;
  return result;
}

inline auto SuperFX::pipe() -> n8 {
  n8 result = regs.pipeline;
  regs.pipeline = readOpcode(++regs.r[15]);
  regs.r[15].modified = false;
  return result;
}

auto SuperFX::flushCache() -> void {
  for(u32 n : range(32)) cache.valid[n] = false;
}

auto SuperFX::readCache(n16 address) -> n8 {
  address = (address + regs.cbr) & 511;
  return cache.buffer[address];
}

auto SuperFX::writeCache(n16 address, n8 data) -> void {
  address = (address + regs.cbr) & 511;
  cache.buffer[address] = data;
  if((address & 15) == 15) cache.valid[address >> 4] = true;
}
