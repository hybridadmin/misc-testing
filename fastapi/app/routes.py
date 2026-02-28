from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.database import get_db
from app.models import Item, Note
from app.schemas import (
    ItemCreate,
    ItemUpdate,
    ItemResponse,
    NoteCreate,
    NoteResponse,
)
from app.cache import cache_get, cache_set, cache_delete, cache_delete_pattern

router = APIRouter()


# -------------------------------------------------------
# Items CRUD
# -------------------------------------------------------


@router.get("/items", response_model=list[ItemResponse])
async def list_items(
    skip: int = 0,
    limit: int = 20,
    db: AsyncSession = Depends(get_db),
):
    cache_key = f"items:list:{skip}:{limit}"
    cached = await cache_get(cache_key)
    if cached is not None:
        return cached

    result = await db.execute(select(Item).offset(skip).limit(limit))
    items = result.scalars().all()
    await cache_set(
        cache_key, [ItemResponse.model_validate(i).model_dump() for i in items]
    )
    return items


@router.post("/items", response_model=ItemResponse, status_code=status.HTTP_201_CREATED)
async def create_item(payload: ItemCreate, db: AsyncSession = Depends(get_db)):
    item = Item(**payload.model_dump())
    db.add(item)
    await db.commit()
    await db.refresh(item)
    await cache_delete_pattern("items:*")
    return item


@router.get("/items/{item_id}", response_model=ItemResponse)
async def get_item(item_id: int, db: AsyncSession = Depends(get_db)):
    cache_key = f"items:{item_id}"
    cached = await cache_get(cache_key)
    if cached is not None:
        return cached

    result = await db.execute(select(Item).where(Item.id == item_id))
    item = result.scalar_one_or_none()
    if item is None:
        raise HTTPException(status_code=404, detail="Item not found")
    await cache_set(cache_key, ItemResponse.model_validate(item).model_dump())
    return item


@router.patch("/items/{item_id}", response_model=ItemResponse)
async def update_item(
    item_id: int,
    payload: ItemUpdate,
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(select(Item).where(Item.id == item_id))
    item = result.scalar_one_or_none()
    if item is None:
        raise HTTPException(status_code=404, detail="Item not found")
    for key, value in payload.model_dump(exclude_unset=True).items():
        setattr(item, key, value)
    await db.commit()
    await db.refresh(item)
    await cache_delete(f"items:{item_id}")
    await cache_delete_pattern("items:list:*")
    return item


@router.delete("/items/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_item(item_id: int, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Item).where(Item.id == item_id))
    item = result.scalar_one_or_none()
    if item is None:
        raise HTTPException(status_code=404, detail="Item not found")
    await db.delete(item)
    await db.commit()
    await cache_delete(f"items:{item_id}")
    await cache_delete_pattern("items:list:*")


# -------------------------------------------------------
# Notes CRUD
# -------------------------------------------------------


@router.get("/notes", response_model=list[NoteResponse])
async def list_notes(
    skip: int = 0,
    limit: int = 20,
    db: AsyncSession = Depends(get_db),
):
    cache_key = f"notes:list:{skip}:{limit}"
    cached = await cache_get(cache_key)
    if cached is not None:
        return cached

    result = await db.execute(select(Note).offset(skip).limit(limit))
    notes = result.scalars().all()
    await cache_set(
        cache_key, [NoteResponse.model_validate(n).model_dump() for n in notes]
    )
    return notes


@router.post("/notes", response_model=NoteResponse, status_code=status.HTTP_201_CREATED)
async def create_note(payload: NoteCreate, db: AsyncSession = Depends(get_db)):
    note = Note(**payload.model_dump())
    db.add(note)
    await db.commit()
    await db.refresh(note)
    await cache_delete_pattern("notes:*")
    return note


@router.get("/notes/{note_id}", response_model=NoteResponse)
async def get_note(note_id: int, db: AsyncSession = Depends(get_db)):
    cache_key = f"notes:{note_id}"
    cached = await cache_get(cache_key)
    if cached is not None:
        return cached

    result = await db.execute(select(Note).where(Note.id == note_id))
    note = result.scalar_one_or_none()
    if note is None:
        raise HTTPException(status_code=404, detail="Note not found")
    await cache_set(cache_key, NoteResponse.model_validate(note).model_dump())
    return note


@router.delete("/notes/{note_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_note(note_id: int, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Note).where(Note.id == note_id))
    note = result.scalar_one_or_none()
    if note is None:
        raise HTTPException(status_code=404, detail="Note not found")
    await db.delete(note)
    await db.commit()
    await cache_delete(f"notes:{note_id}")
    await cache_delete_pattern("notes:list:*")
