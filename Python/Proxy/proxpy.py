import socket
import threading

# Proxy Settings
HOST = '127.0.0.1'
PORT = 8080
BUFFERSIZE = 4096

def handle_client(socket):
    try:
        request = socket.recv(BUFFERSIZE)
        if not request:
            socket.close()
            return
        # Server ermitteln
        first_line = request.split(b'\n')[0]
        parts = first_line.split(b' ')
        method = parts[0].decode('utf-8')
        url = parts[1]
    
        if method == "CONNECT":
            host,port = url.split(b':')
            host = host.decode('utf-8')
            port = int(port)

        elif method == "GET":
            # Entferne HTTP wenn das in URL auftaucht
            if url.startswith(b'http://'):
                url = url[7:]
            host_end = url.find(b'/')
            host = url[:host_end] if host_end != -1 else url
            host = host.decode('utf-8')
            port = 80
            if b':' in host:
                # Wenn wir einen Port angegeben haben...
                port = host.split(b':')[1]
                port = int(port)
            
        
        print(f"Request mit der Methode {method} abgefangen.")
        print(f"Details -> {host}:{port}")

        # Anfrage abfangen
    except:
        pass

def start_proxy():
    proxy_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    proxy_socket.bind((HOST,PORT))
    proxy_socket.listen(5)
    print(f"Proxy läuft brudi -> {HOST}:{PORT}")

    while True:
        client_soket, addr = proxy_socket.accept()
        #print(f"Connection iz da {addr}")

        # Jede Verbindung mit einem Thread abarbeiten
        client_handler = threading.Thread(target=handle_client, args=(client_soket,))
        client_handler.start()


if __name__ == "__main__":
    start_proxy()