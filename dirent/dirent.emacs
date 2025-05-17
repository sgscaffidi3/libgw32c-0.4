static int
is_exec (const char * name)
{
  char * p = strrchr (name, '.');
  return
    (p != NULL
     && (stricmp (p, ".exe") == 0 ||
      stricmp (p, ".com") == 0 ||
      stricmp (p, ".bat") == 0 ||
      stricmp (p, ".cmd") == 0));
}

/* Emulate the Unix directory procedures opendir, closedir, 
   and readdir.  We can't use the procedures supplied in sysdep.c,
   so we provide them here.  */

struct direct dir_static;       /* simulated directory contents */
static HANDLE dir_find_handle = INVALID_HANDLE_VALUE;
static int    dir_is_fat;
static char   dir_pathname[MAXPATHLEN+1];
static WIN32_FIND_DATA dir_find_data;

/* Support shares on a network resource as subdirectories of a read-only
   root directory. */
static HANDLE wnet_enum_handle = INVALID_HANDLE_VALUE;
HANDLE open_unc_volume (char *);
char  *read_unc_volume (HANDLE, char *, int);
void   close_unc_volume (HANDLE);

DIR *
opendir (char *filename)
{
  DIR *dirp;

  /* Opening is done by FindFirstFile.  However, a read is inherent to
     this operation, so we defer the open until read time.  */

  if (dir_find_handle != INVALID_HANDLE_VALUE)
    return NULL;
  if (wnet_enum_handle != INVALID_HANDLE_VALUE)
    return NULL;

  if (is_unc_volume (filename))
    {
      wnet_enum_handle = open_unc_volume (filename);
      if (wnet_enum_handle == INVALID_HANDLE_VALUE)
     return NULL;
    }

  if (!(dirp = (DIR *) malloc (sizeof (DIR))))
    return NULL;

  dirp->dd_fd = 0;
  dirp->dd_loc = 0;
  dirp->dd_size = 0;

  strncpy (dir_pathname, map_w32_filename (filename, NULL), MAXPATHLEN);
  dir_pathname[MAXPATHLEN] = '\0';
  dir_is_fat = is_fat_volume (filename, NULL);

  return dirp;
}

void
closedir (DIR *dirp)
{
  /* If we have a find-handle open, close it.  */
  if (dir_find_handle != INVALID_HANDLE_VALUE)
    {
      FindClose (dir_find_handle);
      dir_find_handle = INVALID_HANDLE_VALUE;
    }
  else if (wnet_enum_handle != INVALID_HANDLE_VALUE)
    {
      close_unc_volume (wnet_enum_handle);
      wnet_enum_handle = INVALID_HANDLE_VALUE;
    }
  xfree ((char *) dirp);
}

struct direct *
readdir (DIR *dirp)
{
  if (wnet_enum_handle != INVALID_HANDLE_VALUE)
    {
      if (!read_unc_volume (wnet_enum_handle, 
                     dir_find_data.cFileName, 
                     MAX_PATH))
     return NULL;
    }
  /* If we aren't dir_finding, do a find-first, otherwise do a find-next. */
  else if (dir_find_handle == INVALID_HANDLE_VALUE)
    {
      char filename[MAXNAMLEN + 3];
      int ln;

      strcpy (filename, dir_pathname);
      ln = strlen (filename) - 1;
      if (!IS_DIRECTORY_SEP (filename[ln]))
     strcat (filename, "\\");
      strcat (filename, "*");

      dir_find_handle = FindFirstFile (filename, &dir_find_data);

      if (dir_find_handle == INVALID_HANDLE_VALUE)
     return NULL;
    }
  else
    {
      if (!FindNextFile (dir_find_handle, &dir_find_data))
     return NULL;
    }
  
  /* Emacs never uses this value, so don't bother making it match
     value returned by stat().  */
  dir_static.d_ino = 1;
  
  dir_static.d_reclen = sizeof (struct direct) - MAXNAMLEN + 3 +
    dir_static.d_namlen - dir_static.d_namlen % 4;
  
  dir_static.d_namlen = strlen (dir_find_data.cFileName);
  strcpy (dir_static.d_name, dir_find_data.cFileName);
  if (dir_is_fat)
    _strlwr (dir_static.d_name);
  else if (!NILP (Vw32_downcase_file_names))
    {
      register char *p;
      for (p = dir_static.d_name; *p; p++)
     if (*p >= 'a' && *p <= 'z')
       break;
      if (!*p)
     _strlwr (dir_static.d_name);
    }
  
  return &dir_static;
}

HANDLE
open_unc_volume (char *path)
{
  NETRESOURCE nr; 
  HANDLE henum;
  int result;

  nr.dwScope = RESOURCE_GLOBALNET; 
  nr.dwType = RESOURCETYPE_DISK; 
  nr.dwDisplayType = RESOURCEDISPLAYTYPE_SERVER; 
  nr.dwUsage = RESOURCEUSAGE_CONTAINER; 
  nr.lpLocalName = NULL; 
  nr.lpRemoteName = map_w32_filename (path, NULL);
  nr.lpComment = NULL; 
  nr.lpProvider = NULL;   

  result = WNetOpenEnum(RESOURCE_GLOBALNET, RESOURCETYPE_DISK,  
               RESOURCEUSAGE_CONNECTABLE, &nr, &henum);

  if (result == NO_ERROR)
    return henum;
  else
    return INVALID_HANDLE_VALUE;
}

char *
read_unc_volume (HANDLE henum, char *readbuf, int size)
{
  DWORD count;
  int result;
  DWORD bufsize = 512;
  char *buffer;
  char *ptr;

  count = 1;
  buffer = alloca (bufsize);
  result = WNetEnumResource (wnet_enum_handle, &count, buffer, &bufsize);
  if (result != NO_ERROR)
    return NULL;

  /* WNetEnumResource returns \\resource\share...skip forward to "share". */
  ptr = ((LPNETRESOURCE) buffer)->lpRemoteName;
  ptr += 2;
  while (*ptr && !IS_DIRECTORY_SEP (*ptr)) ptr++;
  ptr++;

  strncpy (readbuf, ptr, size);
  return readbuf;
}

void
close_unc_volume (HANDLE henum)
{
  if (henum != INVALID_HANDLE_VALUE)
    WNetCloseEnum (henum);
}

DWORD
unc_volume_file_attributes (char *path)
{
  HANDLE henum;
  DWORD attrs;

  henum = open_unc_volume (path);
  if (henum == INVALID_HANDLE_VALUE)
    return -1;

  attrs = FILE_ATTRIBUTE_READONLY | FILE_ATTRIBUTE_DIRECTORY;

  close_unc_volume (henum);

  return attrs;
}

