// Fill these in after creating your Supabase project (Project Settings -> API).
// The anon key is meant to be public: the database is locked down by schema.sql.
window.CONFIG = {
  SUPABASE_URL: "https://pyxpogrjochqqtojnqym.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB5eHBvZ3Jqb2NocXF0b2pucXltIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTMyMTYzOTYsImV4cCI6MjEwODc5MjM5Nn0.x3dXaMcaV9L2ct0zAdQARShuhKdJ9jN82tjftxq3T7o",

  // SHA-256 of the videos-tab password. Generate with:
  //   echo -n "yourpassword" | shasum -a 256
  // This is only a speed bump, not real security (see README).
  VIDEO_PASSWORD_SHA256: "",

  // Intro videos: unlisted YouTube IDs (the part after v=).
  VIDEOS: [
    // { who: "Luis", youtubeId: "dQw4w9WgXcQ" },
  ],
};
