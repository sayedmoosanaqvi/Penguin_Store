from fastapi import APIRouter, HTTPException, Depends
from sqlalchemy.orm import Session
from app.database import SessionLocal
from app.models import Product
from app.adapters.supplier_adapter import DummyJSONAdapter

router = APIRouter(tags=["Supplier Integration"])

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

@router.post("/api/supplier/sync-products")
async def sync_supplier_products(db: Session = Depends(get_db)):
    """
    Syncs inventory using the Adapter pattern. 
    To change suppliers, just swap the adapter class!
    """
    adapter = DummyJSONAdapter() 
    
    try:
        # The adapter fetches and standardizes everything perfectly
        products_data = await adapter.fetch_products()
        added_count = 0
        
        for item in products_data:
            existing_product = db.query(Product).filter(Product.name == item["name"]).first()
            
            if not existing_product:
                new_product = Product(**item) # Unpacks the dictionary directly into the model
                db.add(new_product)
                added_count += 1
                
        db.commit()
        
        return {
            "status": "success", 
            "message": f"Successfully synced {added_count} new products via {adapter.supplier_id}.",
        }

    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=f"Failed to sync with supplier: {str(e)}")