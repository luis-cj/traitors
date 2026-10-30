// Fill these in after creating your Supabase project (Project Settings -> API).
// The anon key is meant to be public: the database is locked down by schema.sql.
window.CONFIG = {
  SUPABASE_URL: "https://pyxpogrjochqqtojnqym.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB5eHBvZ3Jqb2NocXF0b2pucXltIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTMyMTYzOTYsImV4cCI6MjEwODc5MjM5Nn0.x3dXaMcaV9L2ct0zAdQARShuhKdJ9jN82tjftxq3T7o",

  // SHA-256 of the videos-tab password. Generate with:
  //   echo -n "yourpassword" | shasum -a 256
  // This is only a speed bump, not real security (see README).
  VIDEO_PASSWORD_SHA256: "03a94c06c6dc168890b4ac51fcfa1a5f77bee75cc128cc9840f13112258b2aba",

  // Intro videos: unlisted YouTube IDs (the part after v=).
  VIDEOS: [
    { who: "Luis", youtubeId: "6ZIhnrR4HRw", description: "Luis is indeed an angel." },
	{ who: "Zu", youtubeId: "Ix4eG5tv__8", description: "Luis says Zu forgot to mention she deals with spicy animals (and owners) at work" },
	{ who: "Jesús", youtubeId: "IFGJ0sEAhgI", description: "Luis says Jesus forgot to mention corazón adiabático (sounds diabolic - but is it?)" },
	{ who: "Judit", youtubeId: "oPkozDx6zF8", description: "Luis says Judit forgot to mention that she always remembers to make food for you when you arrive late from the airport" },
	{ who: "Alice", youtubeId: "9Qgna0iuxFQ", description: "Luis says Alice forgot to pancakes are life (or death situation)" },
	{ who: "Justo", youtubeId: "M2h-9iig97w", description: "Luis says that Justo forgot to mention he has no mercy on the tennis court" },
	// { who: "Owen", youtubeId: "dQw4w9WgXcQ" },
	// { who: "Martyna", youtubeId: "dQw4w9WgXcQ" },
	{ who: "Gabriela", youtubeId: "HdyX_q53xFY", description: "Luis says Gabriela forgot to mention she cannot survive without matcha and can become dangerous" }
  ],
};
