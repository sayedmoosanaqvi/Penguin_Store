from pydantic import BaseModel
from typing import Optional

# This is the base shape of our product data
class ProductBase(BaseModel):
    name: str
    description: Optional[str] = None
    price: float
    original_price: Optional[float] = None
    image_url: str
    category: str
    rating: Optional[float] = 0.0
    reviews: Optional[int] = 0
    discount_percent: Optional[int] = None
    is_featured: Optional[bool] = False

# We use this when creating a new product
class ProductCreate(ProductBase):
    pass

# We use this when sending product data back to your Flutter app
class Product(ProductBase):
    id: int

    class Config:
        from_attributes = True # This tells Pydantic to read data from SQLAlchemy databases