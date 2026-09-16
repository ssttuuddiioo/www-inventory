// Hands the browser the public Supabase URL and anon key.
// Both are safe to expose; writes are limited by the database functions.
module.exports = (req, res) => {
  res.setHeader("Cache-Control", "public, max-age=300");
  res.status(200).json({
    url: process.env.SUPABASE_URL || "https://tyvecwkxxosxlmsgeywt.supabase.co",
    key: process.env.SUPABASE_ANON_KEY || "",
  });
};
