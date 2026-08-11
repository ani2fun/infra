// Lab seed: one `orders` collection with NESTED documents and an ARRAY field, so Bytebase's
// document view has more than flat key/value pairs to render.
//
// Idempotent: every write is an upsert keyed on _id, so re-running replaces rather than
// duplicates.

const lab = db.getSiblingDB('labdb');

const countries = ['NL', 'DE', 'FR', 'IN', 'US', 'GB'];
const statuses = ['pending', 'paid', 'shipped', 'delivered', 'cancelled'];
const categories = ['tools', 'toys', 'office', 'kitchen'];

for (let i = 1; i <= 30; i++) {
  const itemCount = 1 + (i % 3);
  const items = [];
  for (let j = 0; j < itemCount; j++) {
    const n = i + j;
    items.push({
      sku: 'SKU-' + String(n).padStart(4, '0'),
      name: 'Product ' + n,
      category: categories[n % categories.length],
      quantity: 1 + (n % 4),
      unitPrice: Math.round((5 + n * 3.7) * 100) / 100,
    });
  }

  lab.orders.updateOne(
    { _id: i },
    {
      $set: {
        orderRef: 'ORD-' + String(i).padStart(5, '0'),
        status: statuses[i % statuses.length],
        placedAt: new Date(Date.UTC(2026, 0, 1 + i)),
        // nested subdocument
        customer: {
          id: 1 + (i % 25),
          name: 'Customer ' + (1 + (i % 25)),
          email: 'customer' + (1 + (i % 25)) + '@example.invalid',
          address: {
            city: 'City ' + (1 + (i % 7)),
            country: countries[i % countries.length],
          },
        },
        // array field
        items: items,
        tags: ['lab', 'seed', statuses[i % statuses.length]],
        total: Math.round(items.reduce((s, it) => s + it.quantity * it.unitPrice, 0) * 100) / 100,
      },
    },
    { upsert: true }
  );
}

lab.orders.createIndex({ 'customer.id': 1 });
lab.orders.createIndex({ status: 1, placedAt: -1 });

print('orders: ' + lab.orders.countDocuments());
