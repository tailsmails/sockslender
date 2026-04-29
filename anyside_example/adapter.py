# ./anyside -m server -e "python3 adapter.py server" -c 1024 -d 50 -v
# then ./anyside -m client -l 127.0.0.1:1080 -e "python3 adapter.py client" -c 1024 -d 50 -v
# and then curl -v -x socks5://127.0.0.1:1080 https://duckduckgo.com

import sys
import os
import glob

def transmit(base64_data, mode):
    folder = "./c2s" if mode == "client" else "./s2c"
    os.makedirs(folder, exist_ok=True)
    
    existing_files = glob.glob(f"{folder}/*.txt")
    next_index = len(existing_files) + 1
    
    filename = os.path.join(folder, f"{next_index:06d}.txt")
    
    with open(filename, "w") as f:
        f.write(base64_data + "\n")

def receive(mode):
    folder = "./s2c" if mode == "client" else "./c2s"
    os.makedirs(folder, exist_ok=True)
    
    files = sorted(glob.glob(f"{folder}/*.txt"))
    
    if not files:
        return

    all_content = []
    for filepath in files:
        try:
            with open(filepath, "r") as f:
                content = f.read().strip()
                if content:
                    all_content.append(content)
            os.remove(filepath)
        except Exception:
            pass

    if all_content:
        print("\n".join(all_content))

if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(1)
        
    mode = sys.argv[1]
    action = sys.argv[2]

    if action == "tx" and len(sys.argv) == 4:
        transmit(sys.argv[3], mode)
    elif action == "rx":
        receive(mode)