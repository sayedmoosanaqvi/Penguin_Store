import os
from supabase import create_client, Client
from dotenv import load_dotenv

load_dotenv()

# Supabase Setup
supabase: Client = create_client(
    os.getenv("SUPABASE_URL"), 
    os.getenv("SUPABASE_KEY") # Using your standard API key
)
SUPABASE_BUCKET = "penguin-store-assets"

def check_supabase_storage():
    print(f"Connecting to Supabase bucket: {SUPABASE_BUCKET}...")
    try:
        # List files in the Supabase bucket
        response = supabase.storage.from_(SUPABASE_BUCKET).list()
        
        if not response:
            print("No files found in Supabase bucket.")
            return

        print("\nFiles currently in your Supabase bucket:")
        for item in response:
            print(f" - {item['name']}")
            
        print("\n✅ Connection to Supabase Storage is working perfectly!")
        
    except Exception as e:
        print(f"❌ Failed to connect to Supabase Storage: {e}")

if __name__ == "__main__":
    check_supabase_storage()