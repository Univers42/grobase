38 Prisma Models:

Allergen → allergen/ ✅
ContactMessage → contact/ ✅
DataDeletionRequest → gdpr/ ✅
DeliveryAssignment → delivery/ ✅
Diet → diet/ ✅
Discount → discount/ ✅
Dish → dish/ ✅
DishAllergen → (via dish/allergen) ✅
DishIngredient → ingredient/ ✅
Ingredient → ingredient/ ✅
KanbanColumn → kanban/ ✅
LoyaltyAccount → loyalty/ ✅
LoyaltyTransaction → loyalty/ ✅
Menu → menu/ ✅
MenuImage → image/ ❓
MenuIngredient → ingredient/ ✅
Message → message/ ✅
Notification → notification/ ✅
Order → order/ ✅
OrderMenu → order/ ✅
OrderOrderTag → kanban/ ✅
OrderStatusHistory → order/ ❓
OrderTag → kanban/ ✅
PasswordResetToken → auth/ ✅
Permission → role/ ❓
Publish → ❌ MISSING
ReviewImage → review/ ❓
Role → role/ ✅
RolePermission → role/ ❓
SupportTicket → support/ ✅
Theme → theme/ ✅
TicketMessage → support/ ✅
TimeOffRequest → timeoff/ ✅
User → user/ ✅
UserAddress → ❌ MISSING
UserConsent → gdpr/ ❓
UserSession → session/ ✅
WorkingHours → working-hours/ ✅
Let me check what's already in place:

Now let me check existing services to see what's missing:

Now let me check what's missing. I see:

Publish → review/ ✅ (Publish model is used as reviews)
UserAddress → ❌ MISSING - needs new module
Permission/RolePermission → role/ ✅ (already has permission methods)
ReviewImage → review/ ❌ needs methods added
OrderStatusHistory → order/ ❓ need to check
MenuImage → image/ ✅ (but needs fixing - uses menu_item_id instead of menu_id)