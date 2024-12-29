#  WAS MACHEN WIR HIER ?
#  PEER TO PEER DATA TRANSFER MIT PYTHON
#  NEIN ICH HABE KEINEN KURS

import socket
import threading
import os
import sys
import signal

server_socket = None
client_socket = None



def signal_handler(sig, frame):
    global server_socket
    global client_socket

    print("Signal angekommen...")
    if server_socket:
        server_socket.close()
    
    if client_socket:
        client_socket.close()

    sys.exit(0)

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

def start_server(host='127.0.0.1', port=5001):
    # Socket = Schnittstelle für Kommunication zwischen 2 Devices (Server, Client etc)
    # AF_INET -> IPv4
    # SOCK_STREAM -> TCP
    server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_socket.bind((host, port))
    server_socket.listen(1)
    print(f"Server gestartet auf {host}:{port}")

    try:
        while True:
            conn, addr = server_socket.accept()
            print(f"Connection von {addr} hergestellt.")
            threading.Thread(target=handle_client,args=(conn,)).start()
    finally:
        server_socket.close()


# Client Seite
def start_client(server_host='127.0.0.1', server_port=5001):
    client_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client_socket.connect((server_host,server_port))
    print(f"Mit Server verbunden -> {server_host}:{server_port}")

    try:
        while True:
            choice = input(" 1 - Nachricht senden\n 2 - Data Transfer\n 3- Quit\n Eingabe: ")

            if choice == '1':
                message = input("Deine Nachricht bitte: ")
                client_socket.sendall(message.encode())
                response = client_socket.recv(1024)
                print(f"Antwort: {response.decode()}")
            elif choice == '2':
                filepath = input("Pfad zur Datei: ")
                if os.path.isfile(filepath):
                    send_file(client_socket,filepath)
                else:
                    print("Datei nicht gefunden!")
            elif choice == '3':
                break
            else:
                print("Ungültige Eingabe")
    finally:
        client_socket.close()

# filepath -> C:\Users\hoodi\datei.txt
# filename -> datei.txt
def send_file(client_socket,filepath):
    filename = os.path.basename(filepath)
    client_socket.sendall(f"FILE: {filename}".encode())
    with open(filepath, "rb") as f:
        while chunk := f.read(1024):
            client_socket.sendall(chunk)
    print("Datei wurde versendet...")


def handle_client(connection):
    with connection:
        while True:
            data = connection.recv(1024).decode()
            if not data:
                break
            if data.startswith("FILE:"):
                filename = data.split(":")[1]
                receive_file(connection,filename)
            else:
                print(f"Empfangen {data}")
                connection.sendall(b"Alles chico...")


def receive_file(connection, filename):
    print(f"Empfange Datei: {filename}")
    with open(filename,"wb") as f:
        while True:
            file_data = connection.recv(1024)
            if not file_data:
                break
            f.write(file_data)
    print("Datei erfolgreich gesaved.")





if __name__ == "__main__":
    mode = input("Brudi biste Server (s) oder Client (c) ?")

    if mode == 's':
        host = input("Server Adresse -> Default: 127.0.0.1") or '127.0.0.1'
        port = int(input("Server Port -> Default 5001") or 5001)
        start_server(host, port)

    elif mode == 'c':
        server_host = input("Server Adresse -> Default: 127.0.0.1") or '127.0.0.1'
        server_port = int(input("Server Port -> Default 5001") or 5001)
        start_client(server_host,server_port)
    else:
        print("Baby an der Eingabe stimmt was nicht...")