package com.blacicada;

import java.nio.ByteBuffer;

public class ReadData {
    private ByteBuffer buffer;
    private int read;

    public ByteBuffer getBuffer() {
        return buffer;
    }

    public void setBuffer(ByteBuffer buffer) {
        this.buffer = buffer;
    }

    public int getRead() {
        return read;
    }

    public void setRead(int read) {
        this.read = read;
    }
}
