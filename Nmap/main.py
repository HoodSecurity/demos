import socket
from concurrent.futures import ThreadPoolExecutor

# Checkt ob der übergebene port für die respektive IP offen ist
def getOpenPorts(ip,port):
    print(f"Trying Port: {port}")
    try:
        socket.create_connection((ip,port), timeout=1)
        return port
    except (socket.timeout, socket.error):
        return None

# Durch Banner Grabbing herausfinden was für ein Service läuft
def getBanner(ip,port):
    try:
        with socket.create_connection((ip,port), timeout=3) as connection:
            connection.sendall(b"HELLO\r\n")
            juicy_banner = connection.recv(1024)
            return juicy_banner.strip()
    # Error Handling auf Wish bestellt
    except Exception as e:
        #print(e)
        return None

# Threads auf entspannt
def parallel_scan(ip, ports, max_threads=7):
    open_ports = []
    with ThreadPoolExecutor(max_threads) as executor:
        result = executor.map(lambda p: getOpenPorts(ip,p), ports)
    open_ports = [port for port in result if port is not None]
    return open_ports

# Ports von 0-65535
target = "10.129.7.19"
port_range = range(0,25)


# Nach offenen Ports scannen
open_ports = parallel_scan(target, port_range)
print(f"Offene Ports auf {target} --> {open_ports}")

# Banner grabbing
for port in port_range:
    banner = getBanner(target,port)
    if banner:
        print(f"Port {port} --> Banner: {banner}")