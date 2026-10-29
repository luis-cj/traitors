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
    { who: "Luis", youtubeId: "6ZIhnrR4HRw" },
	{ who: "Zu", youtubeId: "Ix4eG5tv__8" },
	{ who: "Jesús", youtubeId: "IFGJ0sEAhgI" },
	{ who: "Judit", youtubeId: "oPkozDx6zF8" },
	{ who: "Alice", youtubeId: "9Qgna0iuxFQ" },
	{ who: "Justo", youtubeId: "M2h-9iig97w" }
	// { who: "Owen", youtubeId: "dQw4w9WgXcQ" },
	// { who: "Martyna", youtubeId: "dQw4w9WgXcQ" },
	// { who: "Gabriela", youtubeId: "dQw4w9WgXcQ" },
	
  ],
};
