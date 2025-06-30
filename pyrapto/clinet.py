import socket, struct, sys, time

MAXFLOW = 1024 * 1024  # 1 MB

def send_message(sock: socket.socket, msg: str):
    data = msg.encode("utf-8")
    if len(data) > MAXFLOW:
        raise ValueError("Messaggio troppo lungo")
    # Scrivi lunghezza
    sock.sendall(struct.pack('<Q', len(data)))
    # Scrivi contenuto
    sock.sendall(data)

def recv_message(sock: socket.socket) -> str:
    # Leggi 8 byte della lunghezza
    length_bytes = recv_exact(sock, 8)
    length = struct.unpack('<Q', length_bytes)[0]
    
    # Leggi il messaggio
    data = recv_exact(sock, length).decode()
    return data

def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b''
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise
        buf += chunk
    return buf

def main():
    HOST = 'localhost'
    PORT = int(sys.argv[1])

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((HOST, PORT))

    try:
        send_message(sock, "0.1.0")
        send_message(sock, "TESTC")
        while True:
            msg = input("rapto> ").strip()
            if not msg:
                continue
            send_message(sock, msg)
            
            a = time.time()
            risposta = recv_message(sock)
            s = time.time() - a
            
            print(f"{risposta} (resp-time {s:.6f}s)")
    except KeyboardInterrupt:
        pass     
    finally:
        sock.close()

if __name__ == "__main__":
    main()
