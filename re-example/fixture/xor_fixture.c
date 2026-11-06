// SPDX-License-Identifier: MIT
// Test fixture for the stack & XOR string decoder (built with Zig's C compiler for
// x86_64-freestanding at -O0 by Reflet's own tests; never shipped).
// decode_secret builds "Hello, Reflet" XORed with 0x5a on the stack one byte at a time;
// plain_stack builds "cmd.exe" in clear.
static volatile char sink[64];

__attribute__((noinline)) void decode_secret(void) {
    volatile char s[13];
    s[0] = 0x12;
    s[1] = 0x3f;
    s[2] = 0x36;
    s[3] = 0x36;
    s[4] = 0x35;
    s[5] = 0x76;
    s[6] = 0x7a;
    s[7] = 0x08;
    s[8] = 0x3f;
    s[9] = 0x3c;
    s[10] = 0x36;
    s[11] = 0x3f;
    s[12] = 0x2e;
    for (int i = 0; i < 13; i++) sink[i] = s[i] ^ 0x5a;
}

__attribute__((noinline)) void plain_stack(void) {
    volatile char t[8];
    t[0] = 'c'; t[1] = 'm'; t[2] = 'd'; t[3] = '.';
    t[4] = 'e'; t[5] = 'x'; t[6] = 'e'; t[7] = 0;
    for (int i = 0; i < 8; i++) sink[i] = t[i];
}

void _start(void) {
    decode_secret();
    plain_stack();
    for (;;) {}
}
