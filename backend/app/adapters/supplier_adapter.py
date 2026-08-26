import httpx
from abc import ABC, abstractmethod
from typing import List, Dict

# 1. The Target Interface: Every new supplier must follow these rules
class BaseSupplierAdapter(ABC):
    @abstractmethod
    async def fetch_products(self, limit: int = 100) -> List[Dict]:
        """Fetch products from the supplier and return them in a unified format."""
        pass

    @abstractmethod
    async def place_order(self, supplier_sku: str, shipping_address: Dict) -> Dict:
        """Forward a user's order to the external supplier."""
        pass


# 2. The Specific Adapter for DummyJSON
class DummyJSONAdapter(BaseSupplierAdapter):
    def __init__(self):
        self.supplier_id = "API_DUMMYJSON"
        self.fulfillment_type = "DROPSHIP"

    async def fetch_products(self, limit: int = 130) -> List[Dict]:
        url = f"https://dummyjson.com/products?limit={limit}"
        
        async with httpx.AsyncClient() as client:
            response = await client.get(url)
            response.raise_for_status()
            data = response.json()["products"]
            
        standardized_products = []
        for item in data:
            standardized_products.append({
                "name": item["title"],
                "description": item["description"],
                "price": float(item["price"]),
                "original_price": float(item["price"]) / (1 - (float(item.get("discountPercentage", 0)) / 100)),
                "image_url": item["thumbnail"],
                "category": item["category"].upper(),
                "rating": float(item.get("rating", 0.0)),
                "reviews": item.get("stock", 0),
                "is_featured": True if float(item.get("rating", 0.0)) > 4.5 else False,
                "fulfillment_type": self.fulfillment_type,
                "supplier_id": self.supplier_id,
                "supplier_sku": str(item["id"]),
                "cost_price": float(item["price"]) * 0.7  # Simulating a 30% profit margin
            })
            
        return standardized_products
        
    async def place_order(self, supplier_sku: str, shipping_address: Dict) -> Dict:
        # DummyJSON is just for testing, so we mock a successful dispatch response
        return {
            "status": "success", 
            "tracking_number": f"TRK-{supplier_sku}-9982",
            "message": "Order successfully routed to DummyJSON fulfillment."
        }