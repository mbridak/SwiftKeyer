#ifndef C_SERIAL_SHIM_H
#define C_SERIAL_SHIM_H

int serial_wait_ready(int descriptor, int forWrite, int timeoutMilliseconds);
int serial_bytes_available(int descriptor);

#endif
