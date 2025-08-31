from flask import Flask, request, send_file
from datetime import datetime

app = Flask(__name__)

@app.route("/pixel.png")
def pixel():
    # Logge Infos zum Request
    print("==== Neue Anfrage ====")
    print("Zeit:", datetime.now())
    print("IP:", request.headers.get("X-Forwarded-For", request.remote_addr))
    print("User-Agent:", request.headers.get("User-Agent"))
    
    # wir returnen unser 1x1 hood pixel
    return send_file("pixel.png", mimetype="image/png")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
